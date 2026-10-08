#!/bin/bash
# First-boot host setup invoked by cloud-init. Idempotent.
# Arguments: volume label, sudo username.
set -euo pipefail

label="${1:?volume label required}"
admin_user="${2:?sudo user required}"
dev="/dev/disk/by-id/scsi-0Linode_Volume_${label}"

sshd_set() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"
  if grep -Eq "^[#[:space:]]*${key}([[:space:]]|$)" "$file"; then
    sed -i -E "s/^[#[:space:]]*${key}[[:space:]].*/${key} ${value}/" "$file"
  else
    printf '\n%s %s\n' "$key" "$value" >>"$file"
  fi
}

sshd_set PasswordAuthentication no
sshd_set KbdInteractiveAuthentication no
sshd_set PermitRootLogin prohibit-password
sshd_set PubkeyAuthentication yes
sshd_set AllowUsers "root ${admin_user}"

install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-luanti-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AllowUsers root ${admin_user}
EOF

if id "$admin_user" >/dev/null 2>&1; then
  usermod -aG docker "$admin_user"
fi

passwd -l root

found=""
for _ in $(seq 1 60); do
  if [[ -b "$dev" ]]; then
    found="$dev"
    break
  fi
  shopt -s nullglob
  for candidate in /dev/disk/by-id/scsi-0Linode_Volume_*; do
    if [[ "$candidate" == *"$label"* ]]; then
      found="$candidate"
      break
    fi
  done
  shopt -u nullglob
  if [[ -n "$found" ]]; then
    break
  fi
  sleep 5
done

if [[ -z "$found" ]]; then
  echo "world volume did not appear: $dev" >&2
  exit 1
fi

if ! blkid "$found" >/dev/null 2>&1; then
  mkfs.ext4 -F -L "$label" "$found"
fi

install -d -m 0755 /var/lib/luanti
if ! grep -q '[[:space:]]/var/lib/luanti[[:space:]]' /etc/fstab; then
  printf '%s /var/lib/luanti ext4 defaults,noatime,x-systemd.device-timeout=300 0 2\n' "$found" >>/etc/fstab
fi
if ! mountpoint -q /var/lib/luanti; then
  mount /var/lib/luanti
fi

install -d -m 0755 /var/lib/luanti/data
install -d -m 0755 /var/lib/luanti/backups
install -d -m 0700 /var/lib/luanti/password-drop
install -d -m 0755 /etc/luanti
chown 30000:30000 /var/lib/luanti/data /var/lib/luanti/password-drop

systemctl enable docker
systemctl start docker
systemctl enable unattended-upgrades || true

if ! sshd -t; then
  echo "sshd rejected the hardened config" >&2
  exit 1
fi

if ! systemctl reload ssh; then
  systemctl reload sshd
fi
