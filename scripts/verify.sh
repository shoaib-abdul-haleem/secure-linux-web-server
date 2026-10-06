#!/usr/bin/env bash
#
# Checks the result of setup.sh and prints OK or FAIL for every item.
# Usage (on the web server VM): sudo bash scripts/verify.sh

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0" >&2
  exit 1
fi

pass=0
fail=0
ok()  { printf '  [ OK ] %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  [FAIL] %s\n' "$*"; fail=$((fail + 1)); }
check() {
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$description"; else bad "$description"; fi
}
expect() {
  local description=$1 expected=$2 actual=$3
  if [[ "$actual" == "$expected" ]]; then ok "$description"; else bad "$description (got: ${actual:-nothing})"; fi
}
section() { printf '\n%s\n' "$*"; }

# ---------------------------------------------------------------------------
section "Services"
check "nginx is running"        systemctl is-active --quiet nginx
check "ssh is running"          systemctl is-active --quiet ssh
check "fail2ban is running"     systemctl is-active --quiet fail2ban
check "nginx config is valid"   nginx -t
check "automatic updates are configured" test -f /etc/apt/apt.conf.d/20auto-upgrades

# ---------------------------------------------------------------------------
section "Firewall"
ufw_status="$(ufw status verbose 2>/dev/null || true)"
check "UFW is active"                        grep -q '^Status: active' <<<"$ufw_status"
check "default policy: deny incoming"        grep -q 'Default: deny (incoming), allow (outgoing)' <<<"$ufw_status"
check "port 22 allowed (rate limited)"       grep -Eq '^22/tcp +LIMIT IN' <<<"$ufw_status"
check "port 80 allowed"                      grep -Eq '^80/tcp +ALLOW IN' <<<"$ufw_status"
check "port 443 allowed"                     grep -Eq '^443/tcp +ALLOW IN' <<<"$ufw_status"

# Count the IPv4 rules. There must be exactly three.
rule_count="$(awk '/^[0-9]+(\/tcp|\/udp)? +(ALLOW|LIMIT|DENY)/ && !/\(v6\)/ {n++} END {print n+0}' <<<"$ufw_status")"
expect "exactly 3 firewall rules" 3 "$rule_count"

# ---------------------------------------------------------------------------
section "Listening ports (outside loopback)"
unexpected=""
while read -r addr; do
  port="${addr##*:}"
  case "$addr" in 127.*|"[::1]"*|"::1"*) continue ;; esac
  case "$port" in 22|80|443) ;; *) unexpected+=" ${addr}" ;; esac
done < <(ss -H -tln | awk '{print $4}')
expect "only ports 22, 80 and 443 are listening" "" "$unexpected"

# ---------------------------------------------------------------------------
section "Web server"
http_result="$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://localhost/ 2>/dev/null || true)"
expect "HTTP redirects to HTTPS" "301 https://localhost/" "$http_result"

headers="$(curl -skI https://localhost/ 2>/dev/null || true)"
check "HTTPS answers with 200" grep -q '^HTTP/[0-9.]* 200' <<<"$headers"
for header in strict-transport-security x-content-type-options x-frame-options content-security-policy referrer-policy permissions-policy; do
  check "header ${header}" grep -qi "^${header}:" <<<"$headers"
done
if grep -qiE '^server: nginx/' <<<"$headers"; then bad "server version is visible"; else ok "server version is hidden"; fi

post_code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST https://localhost/ 2>/dev/null || true)"
expect "POST requests are rejected (403)" 403 "$post_code"

hidden_code="$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/.git/config 2>/dev/null || true)"
expect "hidden files return 404" 404 "$hidden_code"

# ---------------------------------------------------------------------------
section "TLS"
nginx_full_config="$(nginx -T 2>/dev/null || true)"
check "only TLS 1.2 and 1.3 enabled" grep -q 'ssl_protocols TLSv1.2 TLSv1.3;' <<<"$nginx_full_config"
check "TLS 1.2 handshake works" bash -c "echo | openssl s_client -connect localhost:443 -tls1_2"
check "TLS 1.3 handshake works" bash -c "echo | openssl s_client -connect localhost:443 -tls1_3"
key_mode="$(stat -c '%a %U' /etc/ssl/private/secure-site.key 2>/dev/null || true)"
expect "private key is root-only (600)" "600 root" "$key_mode"

# ---------------------------------------------------------------------------
section "SSH (effective settings)"
sshd_conf="$(sshd -T 2>/dev/null || true)"
check "root login disabled"        grep -qi '^permitrootlogin no' <<<"$sshd_conf"
check "max 3 authentication tries" grep -qi '^maxauthtries 3' <<<"$sshd_conf"
check "X11 forwarding disabled"    grep -qi '^x11forwarding no' <<<"$sshd_conf"
check "empty passwords refused"    grep -qi '^permitemptypasswords no' <<<"$sshd_conf"
printf '  [INFO] %s\n' "$(grep -i '^passwordauthentication' <<<"$sshd_conf" || echo 'passwordauthentication: unknown')"

# ---------------------------------------------------------------------------
section "fail2ban"
check "sshd jail is active"          fail2ban-client status sshd
check "nginx-limit-req jail is active" fail2ban-client status nginx-limit-req

# ---------------------------------------------------------------------------
printf '\nResult: %d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
