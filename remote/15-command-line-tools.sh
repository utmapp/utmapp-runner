#!/bin/bash
#
# Installs the newest Command Line Tools that softwareupdate offers. Homebrew
# refuses to build from source (the patched squid) with tools older than the
# running macOS, which is what a macOS upgrade leaves behind -- even with a full
# Xcode installed and selected. squid's store ID helper (/usr/bin/python3)
# needs them too.
#
# softwareupdate keeps offering the tools even when that version is already
# installed, so this reinstalls them on every run. It takes a while: skip it
# with "./bootstrap.sh --skip clt" when the tools are known to be current.

. "$(dirname "$0")/../lib/remote.sh"

step "Command Line Tools"
# The marker file makes softwareupdate list the Command Line Tools.
CLT_MARKER=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
touch "$CLT_MARKER"
trap 'rm -f "$CLT_MARKER"' EXIT
label="$(softwareupdate -l 2>/dev/null | sed -nE 's/^[[:space:]]*\* Label: (Command Line Tools.*)$/\1/p' | sort -V | tail -1 || true)"
if [ -n "$label" ]; then
    say "Installing $label (several minutes)"
    sudo softwareupdate -i "$label" --verbose
elif [ ! -d /Library/Developer/CommandLineTools ]; then
    die "the Command Line Tools are not installed and softwareupdate does not offer them"
fi
ok "$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | sed -n 's/^version: /version /p')"
