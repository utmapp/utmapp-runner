#!/bin/bash
#
# Passwordless sudo for the admin account (everything else depends on it) and
# the runner's xcode-select exception. bootstrap.sh runs this over "ssh -t" so
# sudo can ask for the provisioned password the first time.

SKIP_SUDO_CHECK=1
. "$(dirname "$0")/../lib/remote.sh"

step "sudoers"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
render "$SETUP_ROOT/files/sudoers" > "$tmp"

if ! sudo -n true 2>/dev/null; then
    say "sudo will ask for $(id -un)'s password once"
fi
sudo /usr/sbin/visudo -cf "$tmp" >/dev/null || die "generated sudoers file does not parse"
install_file "$tmp" /etc/sudoers.d/runner root:wheel 440
sudo /usr/sbin/visudo -c >/dev/null || die "sudoers configuration is invalid"

sudo -k
sudo -n true 2>/dev/null || die "passwordless sudo still not working for $(id -un)"
ok "passwordless sudo works"
