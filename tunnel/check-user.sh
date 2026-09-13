#!/bin/sh
# ---------------------------------------------------------------------------
# Who may dial in. One `name:password` per line in tunnel/users.
#
# OpenVPN passes the credentials in the environment (`via-env`), so they never
# appear on a command line or in a process list. The file is git-ignored.
#
# Exit 0 accepts, anything else refuses — and OpenVPN says AUTH_FAILED to the
# client, which is what a wrong password should look like.
# ---------------------------------------------------------------------------
USERS=/etc/tunnel/users

[ -f "$USERS" ] || exit 1
[ -n "$username" ] || exit 1
[ -n "$password" ] || exit 1

# Read the file rather than grep for the password: a password with a regular
# expression in it must not match something it is not.
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    u=${line%%:*}
    p=${line#*:}
    if [ "$u" = "$username" ] && [ "$p" = "$password" ]; then
        exit 0
    fi
done < "$USERS"

exit 1
