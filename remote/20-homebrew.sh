#!/bin/bash
#
# Homebrew (which also installs the Command Line Tools) and the packages in
# files/Brewfile, plus shell setup for the admin account.

. "$(dirname "$0")/../lib/remote.sh"

step "Homebrew"
if [ ! -x "$HOMEBREW_PREFIX/bin/brew" ]; then
    say "Installing Homebrew (and the Command Line Tools if missing)"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
fi
eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
ok "$(brew --version | head -1)"

# The Homebrew installer normally takes care of this; make sure, because the
# squid build and squid's store ID helper (/usr/bin/python3) need it.
if ! xcode-select -p >/dev/null 2>&1; then
    say "Installing the Command Line Tools"
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    label="$(softwareupdate -l 2>/dev/null | sed -nE 's/^[*] Label: (Command Line Tools for Xcode-.*)$/\1/p' | sort -V | tail -1)"
    [ -n "$label" ] || die "could not find the Command Line Tools in softwareupdate"
    sudo softwareupdate -i "$label" --verbose
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi

step "Brewfile"
# --no-upgrade: re-running the setup on a live runner must not upgrade build
# dependencies underneath running jobs. Upgrade deliberately with "brew upgrade".
brew bundle install --no-upgrade --file "$SETUP_ROOT/files/Brewfile"

step "Admin shell"
for f in zprofile zshrc; do
    install_rendered "$SETUP_ROOT/files/$f" "$HOME/.$f" "$(id -un):staff" 644
done
git config --global http.postBuffer "$RUNNER_GIT_POSTBUFFER"
ok "git http.postBuffer=$RUNNER_GIT_POSTBUFFER"
