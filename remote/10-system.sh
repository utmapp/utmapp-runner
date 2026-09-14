#!/bin/bash
#
# Machine-wide settings: power, Spotlight, software update, screen sharing and
# SSH.

. "$(dirname "$0")/../lib/remote.sh"

# ------------------------------------------------------------------- power --
# A CI machine never sleeps and comes back by itself after a power cut or hang.
step "Power"
sudo pmset -a sleep 0 displaysleep 0 autorestart 1 womp 1
sudo systemsetup -setrestartfreeze on >/dev/null 2>&1 || true
ok "sleep never, restart after power failure/freeze"

# --------------------------------------------------------------- spotlight --
# Indexing build trees and caches only costs CPU and I/O.
step "Spotlight"
if is_true "$DISABLE_SPOTLIGHT"; then
    sudo mdutil -a -i off >/dev/null 2>&1 || true
    ok "indexing disabled"
else
    sudo mdutil -a -i on >/dev/null 2>&1 || true
    ok "indexing enabled"
fi

# --------------------------------------------------------- software update --
step "Software update"
SU=/Library/Preferences/com.apple.SoftwareUpdate
bool() { is_true "$1" && echo true || echo false; }
sudo defaults write "$SU" AutomaticCheckEnabled -bool true
sudo defaults write "$SU" AutomaticDownload -bool "$(bool "$SOFTWARE_UPDATE_AUTO_DOWNLOAD")"
sudo defaults write "$SU" AutomaticallyInstallMacOSUpdates -bool "$(bool "$SOFTWARE_UPDATE_AUTO_INSTALL_MACOS")"
sudo defaults write "$SU" CriticalUpdateInstall -bool "$(bool "$SOFTWARE_UPDATE_CRITICAL")"
sudo defaults write "$SU" ConfigDataInstall -bool "$(bool "$SOFTWARE_UPDATE_CRITICAL")"
ok "download=$SOFTWARE_UPDATE_AUTO_DOWNLOAD install-macos=$SOFTWARE_UPDATE_AUTO_INSTALL_MACOS critical=$SOFTWARE_UPDATE_CRITICAL"

# ---------------------------------------------------------- remote access --
step "Guest account"
sudo sysadminctl -guestAccount off >/dev/null 2>&1 || true
ok "disabled"

step "Screen sharing"
SS_PLIST=/System/Library/LaunchDaemons/com.apple.screensharing.plist
if is_true "$SCREEN_SHARING"; then
    sudo launchctl enable system/com.apple.screensharing
    sudo launchctl bootstrap system "$SS_PLIST" 2>/dev/null || true
    ok "enabled (vnc://$RUNNER_HOST)"
else
    sudo launchctl bootout system/com.apple.screensharing 2>/dev/null || true
    sudo launchctl disable system/com.apple.screensharing
    ok "disabled"
fi

step "SSH"
# files/authorized_keys: SSH_AUTHORIZED_KEYS_FILE plus the backup's keys, if any.
keys="$SETUP_ROOT/files/authorized_keys"
if [ -f "$keys" ]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
    added=0
    while IFS= read -r key; do
        case "$key" in ''|'#'*) continue ;; esac
        grep -qxF "$key" "$HOME/.ssh/authorized_keys" || { echo "$key" >> "$HOME/.ssh/authorized_keys"; added=$((added + 1)); }
    done < "$keys"
    ok "authorized_keys: added $added key(s)"
fi

# Host keys from backup.sh: clients keep trusting the machine after a re-image.
# bootstrap.sh updates your known_hosts afterwards. Connections that are
# already open are unaffected; sshd reads the keys for each new connection.
restored=0
for key in "$SETUP_ROOT"/secrets/ssh/ssh_host_*_key; do
    [ -f "$key" ] && [ -f "$key.pub" ] || continue
    case "$key" in *_dsa_key) continue ;; esac
    dst="/etc/ssh/$(basename "$key")"
    install_file "$key" "$dst" root:wheel 600
    restored=$((restored + INSTALL_CHANGED))
    install_file "$key.pub" "$dst.pub" root:wheel 644
done
if [ "$restored" -gt 0 ]; then
    sudo sshd -t || die "sshd rejects the restored host keys"
    ok "restored $restored SSH host key(s) from the backup"
fi

HARDENING=/etc/ssh/sshd_config.d/010-ci-runner.conf
if is_true "$SSH_DISABLE_PASSWORD_AUTH"; then
    # Refuse to lock ourselves out: bootstrap.sh reaches this step over key
    # authentication, but check there is a key to log in with regardless.
    [ -s "$HOME/.ssh/authorized_keys" ] || die "no authorized_keys for $(id -un); not disabling password login"
    install_file "$SETUP_ROOT/files/sshd-hardening.conf" "$HARDENING" root:wheel 644
    if ! sudo sshd -t; then
        sudo rm -f "$HARDENING"
        die "sshd rejected the configuration; removed $HARDENING"
    fi
    # macOS starts sshd per connection, so new logins pick this up without a restart.
    ok "password and keyboard-interactive login disabled, root login disabled"
else
    if sudo test -f "$HARDENING"; then sudo rm -f "$HARDENING"; fi
    ok "sshd left at macOS defaults"
fi
