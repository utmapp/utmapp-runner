#!/bin/bash
#
# The patched Squid caching proxy, installed by the squid-patch submodule's own
# deploy.sh. --system runs it as a boot-time LaunchDaemon so it does not depend
# on the admin account being logged in (the machine logs in as the runner).

. "$(dirname "$0")/../lib/remote.sh"
eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"

SQUID_SRC="$SETUP_ROOT/squid-patch"
[ -f "$SQUID_SRC/deploy.sh" ] || die "squid-patch is empty; run: git submodule update --init"

step "Squid"

# Service definitions left by earlier hand-made installs. deploy.sh --system
# replaces them with org.squid-cache.* LaunchDaemons.
for label in com.turing.squid-logrotate homebrew.mxcl.squid sh.brew.squid; do
    plist="$HOME/Library/LaunchAgents/$label.plist"
    [ -f "$plist" ] || continue
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null \
        || launchctl bootout "user/$(id -u)/$label" 2>/dev/null \
        || true
    rm -f "$plist"
    ok "removed legacy LaunchAgent $label"
done

# The CA from backup.sh, so a re-image keeps the same CA. deploy.sh only
# generates one when none exists.
BACKUP_CA="$SETUP_ROOT/secrets/squid"
if [ -f "$BACKUP_CA/squid-self-signed.key" ] && [ -f "$BACKUP_CA/squid-self-signed.crt" ]; then
    conf_dir="$HOMEBREW_PREFIX/etc/squid"
    mkdir -p "$conf_dir"
    had_ca=0
    [ ! -f "$conf_dir/squid-self-signed.crt" ] || had_ca=1
    me="$(id -un):admin"
    install_file "$BACKUP_CA/squid-self-signed.key" "$conf_dir/squid-self-signed.key" "$me" 600
    ca_changed=$INSTALL_CHANGED
    install_file "$BACKUP_CA/squid-self-signed.crt" "$conf_dir/squid-self-signed.crt" "$me" 644
    ca_changed=$((ca_changed + INSTALL_CHANGED))
    pem="$BACKUP_CA/squid-self-signed.pem"
    [ -f "$pem" ] || pem="$BACKUP_CA/squid-self-signed.crt"
    install_file "$pem" "$conf_dir/squid-self-signed.pem" "$me" 644
    [ ! -f "$BACKUP_CA/squid-self-signed_dhparam.pem" ] \
        || install_file "$BACKUP_CA/squid-self-signed_dhparam.pem" "$conf_dir/squid-self-signed_dhparam.pem" "$me" 644
    if [ "$ca_changed" -gt 0 ] && [ "$had_ca" = 1 ]; then
        # Certificates Squid generated for bumped hosts are signed by the CA
        # being replaced; deploy.sh re-creates the database.
        rm -rf "$HOMEBREW_PREFIX/var/logs/ssl_db"
        warn "replaced a different CA with the backup; cleared the generated-certificate database"
        warn "restart the runners so running jobs do not hold on to the old CA"
    fi
    ok "Squid CA from the backup: $(openssl x509 -in "$conf_dir/squid-self-signed.crt" -noout -subject -enddate | tr '\n' ' ')"
fi

args=(--system)
tap_formula="$(brew --repository)/Library/Taps/osy/homebrew-local/Formula/squid.rb"
if brew list --versions squid >/dev/null 2>&1 \
    && [ -f "$tap_formula" ] && cmp -s "$tap_formula" "$SQUID_SRC/squid.rb"; then
    # Rebuilding takes minutes and restarts the proxy under running jobs;
    # only do it when the formula (and therefore the patch) changed.
    say "squid is already built from this formula; refreshing config and service only"
    args+=(--skip-install)
fi
# shellcheck disable=SC2206 # word splitting is intended
[ -z "$SQUID_DEPLOY_ARGS" ] || args+=($SQUID_DEPLOY_ARGS)

bash "$SQUID_SRC/deploy.sh" "${args[@]}"

grep -qE "^http_port ${SQUID_PROXY_HOST//./\\.}:${SQUID_PROXY_PORT}([[:space:]]|$)" "$HOMEBREW_PREFIX/etc/squid.conf" \
    || warn "squid.conf does not listen on $SQUID_PROXY_HOST:$SQUID_PROXY_PORT; fix SQUID_PROXY_* in config.env"

# The Actions runner (.NET), URLSession, SwiftPM and xcodebuild ignore
# SSL_CERT_FILE and validate against the keychain, so the CA must be a trusted
# root there or every bumped host fails with UntrustedRoot. macOS asks for
# confirmation on screen before adding a trusted root, and on macOS 27 even
# root cannot relax that (authorizationdb write returns -60005), so this
# cannot be done over SSH. Trust survives reboots; only a re-image loses it.
ca_crt="$HOMEBREW_PREFIX/etc/squid/squid-self-signed.crt"
if ca_trusted "$ca_crt"; then
    ok "Squid CA is trusted in the System keychain"
else
    warn "the Squid CA is not trusted in the System keychain; jobs will fail with UntrustedRoot"
    warn "on the runner's screen (Screen Sharing), run in Terminal and confirm the dialog:"
    warn "  sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $ca_crt"
fi
true
