#!/bin/bash
# Print Luanti join, leave, and allowlist-rejection lines from the last 7 days.
#
# This is the only command the stats user's SSH key can run. authorized_keys
# sets command= to this path. Arguments and SSH_ORIGINAL_COMMAND are ignored
# input from the client, not a way to choose a different command.
#
# The container is started with --rm, and the nightly backup restarts it, so
# `docker logs` only has lines since the last start. journald keeps the unit's
# stdout across those restarts. Reading the journal requires root. This script
# re-execs itself through sudo. The sudoers entry allows this path with no
# arguments and nothing else. The stats user is not in the sudo or docker groups.
set -euo pipefail

unset SSH_ORIGINAL_COMMAND || true

if [[ "$#" -ne 0 ]]; then
  echo "luanti-weekly-logs: arguments are not accepted" >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  exec /usr/bin/sudo -n -- /usr/local/sbin/luanti-weekly-logs
fi

export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
unset SYSTEMD_PAGER || true

# Tight on purpose. A chat line that mentions "joins game" must not leave
# the host. The engine writes "joins game. List of players:" and the allowlist
# mod writes the rejected-name line.
pattern='[A-Za-z0-9_-]+ \[[^]]*\] joins game[.] List of players:|[A-Za-z0-9_-]+ leaves game[.] List of players:|\[player_allowlist\] rejected name'

set +e
/usr/bin/journalctl \
  --unit=luanti.service \
  --since="7 days ago" \
  --no-pager \
  --output=short-iso \
  | /usr/bin/grep -E -- "$pattern"
statuses=("${PIPESTATUS[@]}")
set -e

journal_status="${statuses[0]:-1}"
grep_status="${statuses[1]:-1}"
if [[ "$journal_status" -ne 0 ]]; then
  echo "luanti-weekly-logs: journalctl failed" >&2
  exit "$journal_status"
fi
# grep exits 1 when the week has no matching lines. That is an empty report.
if [[ "$grep_status" -ne 0 && "$grep_status" -ne 1 ]]; then
  exit "$grep_status"
fi
exit 0
