# Sourced by every remote/*.sh step. Runs on the runner as ADMIN_USER.

set -euo pipefail

SETUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SETUP_ROOT/lib/common.sh"

[ "$(uname -s)" = Darwin ] || die "remote steps must run on macOS"
[ "$(id -u)" != 0 ] || die "run as the admin user, not root (steps use sudo where needed)"
[ -f "$SETUP_ROOT/config.resolved.env" ] || die "missing config.resolved.env; run through bootstrap.sh"

set -a
. "$SETUP_ROOT/config.resolved.env"
set +a

# Derived values, exported for templates.
export SQUID_CONF_DIR="$HOMEBREW_PREFIX/etc/squid"
export SQUID_CA_PEM="$SQUID_CONF_DIR/squid-self-signed.pem"
export SQUID_CA_BUNDLE="$SQUID_CONF_DIR/ca-bundle.pem"
export PATH="$HOMEBREW_PREFIX/bin:$HOMEBREW_PREFIX/sbin:$PATH"

if id "$RUNNER_USER" >/dev/null 2>&1; then
    RUNNER_HOME="$(dscl . -read "/Users/$RUNNER_USER" NFSHomeDirectory | awk '{print $2}')"
    RUNNER_UID="$(id -u "$RUNNER_USER")"
else
    RUNNER_HOME="/Users/$RUNNER_USER"
    RUNNER_UID=""
fi
export RUNNER_HOME RUNNER_UID
export RUNNERS_ROOT="$RUNNER_HOME/$RUNNERS_DIR"

if [ -z "${SKIP_SUDO_CHECK:-}" ]; then
    sudo -n true 2>/dev/null || die "passwordless sudo is not set up for $(id -un); run the 'sudo' step"
fi

# as_runner <command...>: runs a command as RUNNER_USER with its own HOME.
# as_runner_in <dir> <command...>: the same, from inside <dir>.
as_runner() {
    as_runner_in / "$@"
}
as_runner_in() {
    local dir="$1"; shift
    sudo -u "$RUNNER_USER" -H env PATH="$PATH" /bin/bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

# install_file <src> <dst> <owner:group> <mode>: copies src to dst (using sudo)
# when the contents differ, keeping a timestamped backup of what was there.
# Sets INSTALL_CHANGED to 1 if the file was written, 0 if it was already current.
INSTALL_CHANGED=0
install_file() {
    local src="$1" dst="$2" owner="$3" mode="$4"
    INSTALL_CHANGED=0
    if sudo test -f "$dst" && sudo cmp -s "$src" "$dst"; then
        sudo chown "$owner" "$dst"
        sudo chmod "$mode" "$dst"
        ok "$dst unchanged"
        return 0
    fi
    if sudo test -f "$dst"; then
        sudo cp -p "$dst" "$dst.$(date +%Y%m%d%H%M%S).bak"
        warn "$dst differed; previous version saved as .bak"
    fi
    sudo mkdir -p "$(dirname "$dst")"
    sudo install -m "$mode" -o "${owner%%:*}" -g "${owner#*:}" "$src" "$dst"
    INSTALL_CHANGED=1
    ok "installed $dst"
}

# install_rendered <template> <dst> <owner:group> <mode>
install_rendered() {
    local tmp
    tmp="$(mktemp)"
    render "$1" > "$tmp"
    install_file "$tmp" "$2" "$3" "$4"
    rm -f "$tmp"
}

# Reads one line of secret input from stdin (bootstrap.sh pipes it in).
read_secret() {
    local line=""
    IFS= read -r line || true
    printf '%s' "$line"
}

# autologin_works <user>: loginwindow is set to log <user> in automatically AND
# /etc/kcpassword holds that user's current password. sysadminctl can set the
# first without the second (seen on macOS 27), which leaves the machine at the
# login screen after a reboot.
autologin_works() {
    local user="$1"
    [ "$(sudo defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$user" ] \
        && sudo test -f /etc/kcpassword \
        && dscl . -authonly "$user" "$(sudo cat /etc/kcpassword | kcpassword_decode)" >/dev/null 2>&1
}

# ca_trusted <cert>: <cert> is in the System keychain and has admin trust
# settings, which is what add-trusted-cert -d -r trustRoot creates.
ca_trusted() {
    local sha cn
    sha="$(openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g')"
    cn="$(openssl x509 -in "$1" -noout -subject -nameopt multiline | awk -F' = ' '/commonName/ {print $2; exit}')"
    security find-certificate -a -Z /Library/Keychains/System.keychain 2>/dev/null | grep -qix "SHA-256 hash: $sha" \
        && security dump-trust-settings -d 2>/dev/null | grep -qF "$cn"
}
