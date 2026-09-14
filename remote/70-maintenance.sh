#!/bin/bash
#
# Scheduled housekeeping in the runner account: a weekly purge of Xcode,
# SwiftPM and clang caches that waits for the runners to be idle.

. "$(dirname "$0")/../lib/remote.sh"

id "$RUNNER_USER" >/dev/null 2>&1 || die "$RUNNER_USER does not exist; run the 'user' step first"

step "Xcode cache cleanup"
label=local.xcode-cache-cleanup
plist="$RUNNER_HOME/Library/LaunchAgents/$label.plist"

if is_true "$XCODE_CACHE_CLEANUP"; then
    as_runner mkdir -p "$RUNNER_HOME/bin" "$RUNNER_HOME/Library/LaunchAgents"
    install_file "$SETUP_ROOT/files/runner/xcode-cache-cleanup.sh" "$RUNNER_HOME/bin/xcode-cache-cleanup.sh" "$RUNNER_USER:staff" 755
    install_rendered "$SETUP_ROOT/files/runner/$label.plist" "$plist" "$RUNNER_USER:staff" 644
    sudo plutil -lint "$plist" >/dev/null || die "$plist is not a valid plist"
    if [ "$INSTALL_CHANGED" = 1 ] && [ -n "$RUNNER_UID" ] && sudo launchctl print "gui/$RUNNER_UID/$label" >/dev/null 2>&1; then
        sudo launchctl bootout "gui/$RUNNER_UID/$label" 2>/dev/null || true
        sudo launchctl bootstrap "gui/$RUNNER_UID" "$plist"
        ok "reloaded $label"
    fi
    ok "weekday $XCODE_CACHE_CLEANUP_WEEKDAY at $XCODE_CACHE_CLEANUP_HOUR:$(printf %02d "$XCODE_CACHE_CLEANUP_MINUTE")"
else
    if sudo test -f "$plist"; then
        [ -z "$RUNNER_UID" ] || sudo launchctl bootout "gui/$RUNNER_UID/$label" 2>/dev/null || true
        sudo rm -f "$plist"
    fi
    ok "disabled"
fi
