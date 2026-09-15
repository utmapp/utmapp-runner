#!/bin/bash
#
# Read-only health check of everything the other steps set up. Safe to run on
# a live runner at any time: ./bootstrap.sh verify

. "$(dirname "$0")/../lib/remote.sh"
eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"
set +e

failures=0
check() {  # check <description> <command...>
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '\033[1;32m  PASS\033[0m %s\n' "$what"
    else
        printf '\033[1;31m  FAIL\033[0m %s\n' "$what"
        failures=$((failures + 1))
    fi
}
info() { printf '       %s\n' "$*"; }

step "System"
info "$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
check "passwordless sudo for $(id -un)" sudo -n true
check "sudoers valid" sudo /usr/sbin/visudo -c
check "never sleeps" sh -c "pmset -g | grep -qE '^ sleep +0'"
if is_true "$SSH_DISABLE_PASSWORD_AUTH"; then
    check "sshd refuses passwords" sh -c "sudo sshd -T | grep -qx 'passwordauthentication no'"
fi

step "Squid"
check "squid LaunchDaemon running" sh -c "sudo launchctl print system/org.squid-cache.squid | grep -q 'state = running'"
check "no competing squid LaunchAgent" sh -c "! test -f '$HOME/Library/LaunchAgents/homebrew.mxcl.squid.plist' && ! test -f '$HOME/Library/LaunchAgents/sh.brew.squid.plist'"
check "squid pinned in Homebrew" sh -c "brew list --pinned | grep -qx squid"
check "squid binary carries the patch" env LC_ALL=C grep -a -q x-ms-range "$HOMEBREW_PREFIX/opt/squid/sbin/squid"
check "proxy listening on $SQUID_PROXY_HOST:$SQUID_PROXY_PORT" nc -z "$SQUID_PROXY_HOST" "$SQUID_PROXY_PORT"
check "bumped HTTPS through the proxy (CA bundle)" \
    curl -fsS -o /dev/null --max-time 30 --proxy "http://$SQUID_PROXY_HOST:$SQUID_PROXY_PORT" --cacert "$SQUID_CA_BUNDLE" https://www.apple.com/
check "spliced HTTPS through the proxy (github.com)" \
    curl -fsS -o /dev/null --max-time 30 --proxy "http://$SQUID_PROXY_HOST:$SQUID_PROXY_PORT" --cacert "$SQUID_CA_BUNDLE" https://github.com/
info "CA: $(openssl x509 -in "$SQUID_CA_PEM" -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"

step "Xcode"
dev="$(xcode-select -p 2>/dev/null)"
info "selected: $dev"
check "full Xcode selected" sh -c "case '$dev' in /Applications/*.app/Contents/Developer) exit 0;; *) exit 1;; esac"
check "xcodebuild works (license accepted)" xcodebuild -version
info "$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
for c in $XCODE_COMPONENTS; do
    check "$c installed" sh -c "xcodebuild -showComponent '$c' | grep -q 'Status: installed'"
done
xcrun simctl runtime list 2>/dev/null | grep -E '^(iOS|xrOS|visionOS|tvOS|watchOS) ' | while read -r line; do info "$line"; done

step "Runner account"
check "$RUNNER_USER exists" id "$RUNNER_USER"
if [ -n "$AUTOLOGIN_USER" ]; then
    check "automatic login is $AUTOLOGIN_USER (with its current password)" autologin_works "$AUTOLOGIN_USER"
fi
check "$RUNNER_USER has a GUI session" sudo launchctl print "gui/$RUNNER_UID"
for m in $RUNNER_PIP_PACKAGES; do
    check "python: $m" as_runner "$HOMEBREW_PREFIX/bin/python3" -m pip show "$m"
done
for g in $RUNNER_GEMS; do
    check "gem: $g" as_runner /usr/bin/gem list -i "$g"
done

step "Actions runners"
i=1
while [ "$i" -le "$RUNNER_COUNT" ]; do
    dir="$RUNNERS_ROOT/runner-$i"
    name="${RUNNER_NAME_PREFIX}-${i}"
    check "$name registered" sudo test -f "$dir/.runner"
    check "$name .env uses the proxy CA bundle" sudo grep -qx "SSL_CERT_FILE=$SQUID_CA_BUNDLE" "$dir/.env"
    label=""
    sudo test -f "$dir/.service" && label="$(basename "$(sudo cat "$dir/.service")" .plist)"
    check "$name LaunchAgent running" sh -c "sudo launchctl print 'gui/$RUNNER_UID/$label' | grep -q 'state = running'"
    check "$name listener process" pgrep -u "$RUNNER_USER" -f "$dir/bin/Runner.Listener"
    i=$((i + 1))
done
if is_true "$XCODE_CACHE_CLEANUP"; then
    check "cache cleanup scheduled" sudo launchctl print "gui/$RUNNER_UID/local.xcode-cache-cleanup"
fi

echo
if [ "$failures" = 0 ]; then
    printf '\033[1;32mAll checks passed.\033[0m Confirm the runners show as Idle in the Actions runner settings of %s\n' "$GITHUB_URL"
else
    printf '\033[1;31m%d check(s) failed.\033[0m\n' "$failures"
    exit 1
fi
