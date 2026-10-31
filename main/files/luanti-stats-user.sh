#!/bin/bash
# Create the read-only stats user and the one sudoers rule it is allowed to use.
# Idempotent. Run as root from the config push. Cloud-init creates the account
# on a new VM; this script is what creates it on a VM that already booted.
set -euo pipefail

stats_user="${1:?stats user required}"
admin_user="${2:?sudo user required}"
key_file="${3:?authorized_keys file required}"

if [[ ! "$admin_user" =~ ^[a-z][a-z0-9-]{0,30}$ || ! "$stats_user" =~ ^[a-z][a-z0-9-]{0,30}$ ]]; then
  echo "admin and stats users must be short lowercase names" >&2
  exit 1
fi
if [[ "$stats_user" == "$admin_user" || "$stats_user" == "root" ]]; then
  echo "stats user must not be root or the sudo user" >&2
  exit 1
fi
if [[ ! -x /usr/local/sbin/luanti-weekly-logs ]]; then
  echo "luanti-weekly-logs is not installed" >&2
  exit 1
fi

chown root:root /usr/local/sbin/luanti-weekly-logs
chmod 0755 /usr/local/sbin/luanti-weekly-logs

if ! id "$stats_user" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --user-group "$stats_user"
fi
usermod --shell /bin/bash "$stats_user"
passwd -l "$stats_user" >/dev/null

# group membership is the thing that would make this user an admin.
# A single sudoers command below is the whole privilege.
if id -nG "$stats_user" | tr ' ' '\n' | grep -qx sudo; then
  gpasswd -d "$stats_user" sudo
fi
if id -nG "$stats_user" | tr ' ' '\n' | grep -qx docker; then
  gpasswd -d "$stats_user" docker
fi

install -d -m 0755 -o "$stats_user" -g "$stats_user" "/home/${stats_user}"
install -d -m 0700 -o "$stats_user" -g "$stats_user" "/home/${stats_user}/.ssh"
if [[ -s "$key_file" ]]; then
  install -m 0600 -o "$stats_user" -g "$stats_user" "$key_file" "/home/${stats_user}/.ssh/authorized_keys"
  if ! grep -q '^command="/usr/local/sbin/luanti-weekly-logs",no-port-forwarding,no-pty,no-agent-forwarding,no-X11-forwarding ' \
    "/home/${stats_user}/.ssh/authorized_keys"; then
    echo "stats authorized_keys is missing the forced command" >&2
    exit 1
  fi
else
  rm -f "/home/${stats_user}/.ssh/authorized_keys"
fi

sudoers="/etc/sudoers.d/${stats_user}"
tmp="$(mktemp)"
cat >"$tmp" <<EOF
# ${stats_user} may run only the weekly log script, with no arguments.
Defaults:${stats_user} !requiretty
Defaults:${stats_user} env_reset
Defaults:${stats_user} secure_path="/usr/sbin:/usr/bin:/sbin:/bin"
${stats_user} ALL=(root) NOPASSWD: /usr/local/sbin/luanti-weekly-logs ""
EOF
if ! visudo -cf "$tmp" >/dev/null; then
  rm -f "$tmp"
  echo "sudoers file for ${stats_user} was rejected" >&2
  exit 1
fi
install -m 0440 -o root -g root "$tmp" "$sudoers"
rm -f "$tmp"

sshd_set() {
  local key="$1"
  local value="$2"
  local file="$3"
  if grep -Eq "^[#[:space:]]*${key}([[:space:]]|$)" "$file"; then
    sed -i -E "s/^[#[:space:]]*${key}[[:space:]].*/${key} ${value}/" "$file"
  else
    printf '\n%s %s\n' "$key" "$value" >>"$file"
  fi
}

allow="root ${admin_user} ${stats_user}"
sshd_set AllowUsers "$allow" /etc/ssh/sshd_config
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-luanti-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
AllowUsers ${allow}
EOF

install -d -m 0755 /run/sshd
if ! sshd -t; then
  echo "sshd rejected AllowUsers for ${stats_user}" >&2
  exit 1
fi
systemctl try-reload-or-restart ssh.service \
  || systemctl try-reload-or-restart sshd.service \
  || true

# Do not pipe sudo into grep -q. grep -q closes the pipe early, sudo dies
# with SIGPIPE, and pipefail turns a successful listing into a failure.
sudo_list="$(sudo -n -l -U "$stats_user" 2>&1 || true)"
if ! grep -F -q '/usr/local/sbin/luanti-weekly-logs' <<<"$sudo_list"; then
  echo "sudoers does not allow the stats log script" >&2
  exit 1
fi
