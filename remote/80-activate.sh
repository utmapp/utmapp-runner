#!/bin/bash
#
# Starts the runner account's LaunchAgents (the Actions runners and the cache
# cleanup) in its GUI session.
#
# Those agents only exist inside RUNNER_USER's login session. Automatic login
# creates it at boot; until then there is nothing to load them into, and this
# step exits with status 3 so bootstrap.sh can offer to reboot.

. "$(dirname "$0")/../lib/remote.sh"

id "$RUNNER_USER" >/dev/null 2>&1 || die "$RUNNER_USER does not exist; run the 'user' step first"

step "Runner LaunchAgents"
if ! sudo launchctl print "gui/$RUNNER_UID" >/dev/null 2>&1; then
    warn "$RUNNER_USER has no GUI login session yet"
    if [ "$AUTOLOGIN_USER" = "$RUNNER_USER" ]; then
        warn "reboot so automatic login starts it: the agents then load by themselves"
    else
        warn "AUTOLOGIN_USER is '$AUTOLOGIN_USER': log in as $RUNNER_USER via Screen Sharing, or they will not run"
    fi
    exit 3
fi

loaded=0
# ~/Library is private to the runner account, hence sudo to list it.
for plist in $(sudo find "$RUNNER_HOME/Library/LaunchAgents" -maxdepth 1 -name '*.plist' | sort); do
    label="$(sudo plutil -extract Label raw -o - "$plist")"
    case "$label" in actions.runner.*|local.xcode-cache-cleanup) ;; *) continue ;; esac
    if sudo launchctl print "gui/$RUNNER_UID/$label" >/dev/null 2>&1; then
        ok "$label already loaded"
    else
        sudo launchctl enable "gui/$RUNNER_UID/$label"
        sudo launchctl bootstrap "gui/$RUNNER_UID" "$plist"
        ok "$label loaded"
        loaded=$((loaded + 1))
    fi
done
[ "$loaded" = 0 ] || sleep 10   # give the listeners a moment before verify
