#!/bin/bash
#
# Homebrew and the packages in files/Brewfile, plus shell setup for the admin
# account. The Command Line Tools are the separate "clt" step.

. "$(dirname "$0")/../lib/remote.sh"

step "Homebrew"
if [ ! -x "$HOMEBREW_PREFIX/bin/brew" ]; then
    say "Installing Homebrew (and the Command Line Tools if missing)"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/null
fi
eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
ok "$(brew --version | head -1)"

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
