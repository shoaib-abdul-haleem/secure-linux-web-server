#!/usr/bin/env bash
#
# Secure web server setup for Ubuntu Server 22.04 / 24.04 LTS.
# Installs Nginx, UFW and fail2ban and applies the configuration from this repository.
#
# Usage:
#   sudo bash scripts/setup.sh
#   sudo bash scripts/setup.sh --disable-ssh-passwords   # also turn off SSH password login
#
# Run it on the VM that will be the web server, from inside the cloned repository.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_NAME="secure-site"
WEB_ROOT="/var/www/${SITE_NAME}"
CERT="/etc/ssl/certs/${SITE_NAME}.crt"
KEY="/etc/ssl/private/${SITE_NAME}.key"
DISABLE_SSH_PASSWORDS=false

for arg in "$@"; do
  case "$arg" in
    --disable-ssh-passwords) DISABLE_SSH_PASSWORDS=true ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0" >&2
  exit 1
fi

step() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
step "1/8 Update the system"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y -o Dpkg::Options::="--force-confold" upgrade

# ---------------------------------------------------------------------------
step "2/8 Install packages"
apt-get install -y -o Dpkg::Options::="--force-confold" nginx ufw fail2ban unattended-upgrades openssl curl

# ---------------------------------------------------------------------------
step "3/8 Enable automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ---------------------------------------------------------------------------
step "4/8 Create a self-signed TLS certificate"
if [[ -f "$CERT" && -f "$KEY" ]]; then
  echo "Certificate already exists, keeping it."
else
  # Put the VM's own IPv4 addresses into the certificate so https://<ip> matches.
  san="DNS:localhost,DNS:homelab.local,IP:127.0.0.1"
  for ip in $(hostname -I 2>/dev/null || true); do
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && san+=",IP:${ip}"
  done
  openssl req -x509 -nodes -days 365 \
    -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$KEY" -out "$CERT" \
    -subj "/CN=homelab.local" \
    -addext "subjectAltName=${san}"
  chmod 600 "$KEY"
  chmod 644 "$CERT"
  echo "Certificate valid for: ${san}"
fi

# ---------------------------------------------------------------------------
step "5/8 Deploy the Nginx configuration"
[[ -f /etc/nginx/nginx.conf.orig ]] || cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
install -d -m 755 /etc/nginx/snippets /etc/nginx/sites-available /etc/nginx/sites-enabled
install -m 644 "${REPO_DIR}/nginx/nginx.conf" /etc/nginx/nginx.conf
install -m 644 "${REPO_DIR}"/nginx/snippets/*.conf /etc/nginx/snippets/
install -m 644 "${REPO_DIR}/nginx/sites-available/${SITE_NAME}.conf" "/etc/nginx/sites-available/${SITE_NAME}.conf"
rm -f /etc/nginx/sites-enabled/default
ln -sf "/etc/nginx/sites-available/${SITE_NAME}.conf" "/etc/nginx/sites-enabled/${SITE_NAME}.conf"

# The web root belongs to root. The nginx worker (www-data) can read it but not change it.
install -d -m 755 "$WEB_ROOT"
install -m 644 "${REPO_DIR}"/nginx/html/* "$WEB_ROOT"/

nginx -t
systemctl enable nginx
systemctl restart nginx

# ---------------------------------------------------------------------------
step "6/8 Harden SSH"
install -d -m 755 /etc/ssh/sshd_config.d
install -m 644 "${REPO_DIR}/ssh/10-hardening.conf" /etc/ssh/sshd_config.d/10-hardening.conf

if [[ "$DISABLE_SSH_PASSWORDS" == true ]]; then
  admin="${SUDO_USER:-}"
  home_dir=""
  [[ -n "$admin" ]] && home_dir="$(getent passwd "$admin" | cut -d: -f6)"
  if [[ -z "$home_dir" || ! -s "${home_dir}/.ssh/authorized_keys" ]]; then
    rm -f /etc/ssh/sshd_config.d/10-hardening.conf
    echo "Refusing to disable SSH passwords: no key found in ~/.ssh/authorized_keys for '${admin:-?}'." >&2
    echo "Add your public key first (see README), then run this script again." >&2
    exit 1
  fi
  install -m 644 "${REPO_DIR}/ssh/11-disable-password-auth.conf" /etc/ssh/sshd_config.d/11-disable-password-auth.conf
fi

# sshd -t needs this directory. After the package upgrade in step 1 the ssh service can be
# stopped (Ubuntu 24.04 starts it on demand through ssh.socket), and the directory is gone.
install -d -m 755 /run/sshd

# Never reload sshd with a broken config.
if ! sshd -t; then
  rm -f /etc/ssh/sshd_config.d/10-hardening.conf /etc/ssh/sshd_config.d/11-disable-password-auth.conf
  echo "sshd config test failed, hardening files removed." >&2
  exit 1
fi
# Existing SSH sessions stay connected. If the service was stopped, this starts it.
systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd

# ---------------------------------------------------------------------------
step "7/8 Configure fail2ban"
install -m 644 "${REPO_DIR}/fail2ban/jail.local" /etc/fail2ban/jail.local
fail2ban-client -t
systemctl enable fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
step "8/8 Enable the firewall (only 22, 80, 443)"
bash "${REPO_DIR}/firewall/ufw-setup.sh"

# ---------------------------------------------------------------------------
printf '\nDone. Listening sockets:\n'
ss -tln
printf '\nOpen this in a browser (accept the self-signed certificate warning):\n'
for ip in $(hostname -I 2>/dev/null || true); do
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "  https://${ip}/"
done
printf '\nNext: sudo bash scripts/verify.sh\n'
