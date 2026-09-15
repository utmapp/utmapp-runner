#!/bin/bash
#
# The unprivileged account the GitHub Actions runners run as, automatic login
# (the runners are LaunchAgents and need its GUI session), and its shell,
# proxy, git, Python and Ruby setup.
#
# stdin: line 1 = RUNNER_USER's password, line 2 = AUTOLOGIN_USER's password.
# Either may be empty when bootstrap.sh determined it is not needed.

. "$(dirname "$0")/../lib/remote.sh"
runner_password="$(read_secret)"
autologin_password="$(read_secret)"
exec </dev/null

# ------------------------------------------------------------------ account --
step "User $RUNNER_USER"
if id "$RUNNER_USER" >/dev/null 2>&1; then
    ok "exists (uid $(id -u "$RUNNER_USER"))"
else
    [ -n "$runner_password" ] || die "a password is needed to create $RUNNER_USER"
    # Without -adminUser/-adminPassword the account gets no Secure Token. That
    # only matters for FileVault, which a remote CI machine cannot use anyway.
    sudo sysadminctl -addUser "$RUNNER_USER" -fullName "$RUNNER_FULL_NAME" \
        -shell /bin/zsh -home "/Users/$RUNNER_USER" -password "$runner_password" 2>&1 \
        | grep -v "Secure token" || true
    id "$RUNNER_USER" >/dev/null 2>&1 || die "failed to create $RUNNER_USER"
    sudo createhomedir -c -u "$RUNNER_USER" >/dev/null 2>&1 || true
    ok "created (uid $(id -u "$RUNNER_USER"))"
fi
RUNNER_HOME="$(dscl . -read "/Users/$RUNNER_USER" NFSHomeDirectory | awk '{print $2}')"
RUNNER_UID="$(id -u "$RUNNER_USER")"
RUNNERS_ROOT="$RUNNER_HOME/$RUNNERS_DIR"
export RUNNER_HOME RUNNER_UID RUNNERS_ROOT
if ! sudo test -d "$RUNNER_HOME"; then
    sudo mkdir -p "$RUNNER_HOME"
    sudo chown "$RUNNER_USER:staff" "$RUNNER_HOME"
    sudo chmod 750 "$RUNNER_HOME"
fi

# ---------------------------------------------------------------- autologin --
step "Automatic login"
if [ -z "$AUTOLOGIN_USER" ]; then
    sudo sysadminctl -autologin off >/dev/null 2>&1 || true
    ok "disabled"
elif autologin_works "$AUTOLOGIN_USER" && [ -z "$autologin_password" ]; then
    ok "already $AUTOLOGIN_USER"
else
    [ -n "$autologin_password" ] || die "a password is needed to enable automatic login for $AUTOLOGIN_USER"
    # A wrong password here still "succeeds" and only fails at the next boot.
    dscl . -authonly "$AUTOLOGIN_USER" "$autologin_password" >/dev/null 2>&1 \
        || die "the password for $AUTOLOGIN_USER is incorrect"
    sudo sysadminctl -autologin set -userName "$AUTOLOGIN_USER" -password "$autologin_password" >/dev/null 2>&1 || true
    # sysadminctl does not reliably write /etc/kcpassword (on macOS 27 it left
    # the previous user's password there), so write both settings ourselves.
    kc="$(mktemp)"
    printf '%s' "$autologin_password" | kcpassword_encode > "$kc"
    sudo install -m 600 -o root -g wheel "$kc" /etc/kcpassword
    rm -f "$kc"
    sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$AUTOLOGIN_USER"
    autologin_works "$AUTOLOGIN_USER" || die "automatic login for $AUTOLOGIN_USER still does not verify"
    ok "$AUTOLOGIN_USER (takes effect at the next boot)"
fi

# -------------------------------------------------------------------- shell --
step "Runner shell and proxy settings"
as_runner mkdir -p "$RUNNER_HOME/bin" "$RUNNER_HOME/.gitcache" "$RUNNER_HOME/Library/LaunchAgents" "$RUNNER_HOME/Library/Logs"
owner="$RUNNER_USER:staff"
install_rendered "$SETUP_ROOT/files/zprofile"      "$RUNNER_HOME/.zprofile" "$owner" 644
install_rendered "$SETUP_ROOT/files/zshrc"         "$RUNNER_HOME/.zshrc"    "$owner" 644
install_rendered "$SETUP_ROOT/files/runner/curlrc" "$RUNNER_HOME/.curlrc"   "$owner" 644
install_rendered "$SETUP_ROOT/files/runner/boto"   "$RUNNER_HOME/.boto"     "$owner" 644

step "Runner git config"
as_runner git config --global cache.cachepath "$RUNNER_HOME/.gitcache"
as_runner git config --global http.postBuffer "$RUNNER_GIT_POSTBUFFER"
as_runner git config --global http.sslVerify "$RUNNER_GIT_SSLVERIFY"
ok "$(as_runner git config --global --list | tr '\n' ' ')"

# ---------------------------------------------------------------- packages --
step "Runner Python packages"
if [ -n "$RUNNER_PIP_PACKAGES" ]; then
    # shellcheck disable=SC2086
    as_runner "$HOMEBREW_PREFIX/bin/python3" -m pip install --quiet --user --break-system-packages $RUNNER_PIP_PACKAGES
    ok "$RUNNER_PIP_PACKAGES"
fi

step "Runner Ruby gems"
if [ -n "$RUNNER_GEMS" ]; then
    # shellcheck disable=SC2086
    as_runner /usr/bin/gem install --user-install --no-document $RUNNER_GEMS 2>&1 \
        | grep -v "PATH environment variable" || true
    ok "$RUNNER_GEMS"
fi
