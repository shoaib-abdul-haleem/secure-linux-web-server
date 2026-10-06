#!/usr/bin/env bash
#
# Configure UFW so that only SSH (22), HTTP (80) and HTTPS (443) are reachable.
# Everything else coming in is dropped.
#
# Usage: sudo bash firewall/ufw-setup.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash $0" >&2
  exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ufw
fi

# Start from a clean rule set so the result is the same on every run.
ufw --force reset

# Default policy: drop all incoming traffic, allow outgoing (needed for apt and DNS).
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

# The SSH rule must exist before the firewall is enabled,
# otherwise the current SSH session is cut off and you are locked out.
# "limit" allows SSH but blocks an IP that opens 6 or more connections within 30 seconds.
ufw limit 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

ufw logging low
ufw --force enable

echo
ufw status verbose
