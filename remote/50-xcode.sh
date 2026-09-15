#!/bin/bash
#
# Xcode from a .xip (Apple offers no unattended download), then license,
# first-launch packages, simulator runtimes and extra components.
#
# The .xip comes from XCODE_XIP_REMOTE, a path on this machine: either where
# bootstrap.sh uploaded --xcode-xip, or an .xip that was already here
# (XCODE_XIP_ON_RUNNER / --xcode-xip-on-runner). Otherwise it is downloaded from
# XCODE_XIP_URL. With none of these, the installed Xcode is (re)configured.
#
# With XCODE_DELETE_XIP, the .xip is deleted only after the whole step has
# succeeded, so a failed run can be retried without copying it again.

. "$(dirname "$0")/../lib/remote.sh"
eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"

# version_ge A B: true if dotted version A >= B
version_ge() {
    local IFS=. i x y
    # shellcheck disable=SC2206
    local a=($1) b=($2)
    for i in 0 1 2 3; do
        x="${a[i]:-0}"; y="${b[i]:-0}"
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 0
}

plist_get() { defaults read "$1" "$2" 2>/dev/null; }

step "Xcode"
xip="${XCODE_XIP_REMOTE:-}"
case "$xip" in
    "~/"*) xip="$HOME/${xip#"~/"}" ;;
    ""|/*) ;;
    *) xip="$HOME/$xip" ;;
esac
if [ -z "$xip" ] && [ -n "$XCODE_XIP_URL" ]; then
    mkdir -p "$HOME/Downloads"
    xip="$HOME/Downloads/$(basename "${XCODE_XIP_URL%%\?*}")"
    say "Downloading $(basename "$xip")"
    curl -fL --retry 3 -C - -o "$xip" "$XCODE_XIP_URL"
fi

dest=""
if [ -n "$xip" ]; then
    [ -f "$xip" ] || die "no such file: $xip"

    # The expanded app is roughly 3x the archive, and both exist at once.
    need_kb=$(( $(stat -f %z "$xip") / 1024 * 3 ))
    free_kb="$(df -k "$HOME" | awk 'NR==2 {print $4}')"
    [ "$free_kb" -gt "$need_kb" ] || die "not enough disk space to expand $(basename "$xip") (need ~$((need_kb / 1048576)) GB)"

    # Expand next to /Applications (same volume) so the final move is a rename.
    work="$(mktemp -d "$HOME/.xcode-expand.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    say "Expanding $(basename "$xip") (several minutes)"
    if command -v unxip >/dev/null; then
        (cd "$work" && unxip "$xip")
    else
        (cd "$work" && xip --expand "$xip")
    fi
    app="$(find "$work" -maxdepth 1 -name 'Xcode*.app' | head -1)"
    [ -n "$app" ] || die "no Xcode*.app in $(basename "$xip")"

    version="$(plist_get "$app/Contents/Info" CFBundleShortVersionString)"
    build="$(plist_get "$app/Contents/version" ProductBuildVersion)"
    min_os="$(plist_get "$app/Contents/Info" LSMinimumSystemVersion)"
    os="$(sw_vers -productVersion)"
    version_ge "$os" "$min_os" \
        || die "Xcode $version ($build) requires macOS $min_os, this runner has $os. Update macOS or pick an older Xcode (tools/latest-xcode.sh $os)."

    name="$XCODE_APP_NAME"
    if [ -z "$name" ]; then
        case "$(basename "$app")" in
            *beta*) name="Xcode_${version}_beta.app" ;;
            *)      name="Xcode_${version}.app" ;;
        esac
    fi
    dest="/Applications/$name"

    if [ -d "$dest" ]; then
        existing="$(plist_get "$dest/Contents/version" ProductBuildVersion)"
        [ "$existing" = "$build" ] \
            || die "$dest already exists with build $existing (installing $build); remove it or set XCODE_APP_NAME"
        ok "$name ($build) already installed"
    else
        sudo mv "$app" "$dest"
        ok "installed $dest ($version, $build)"
    fi
    rm -rf "$work"
    trap - EXIT
else
    current="$(xcode-select -p 2>/dev/null || true)"
    case "$current" in
        /Applications/*.app/Contents/Developer) dest="${current%/Contents/Developer}" ;;
        *) dest="$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1 || true)" ;;
    esac
    if [ -z "$dest" ]; then
        warn "no Xcode installed and no .xip given; skipping."
        warn "download one (tools/latest-xcode.sh) and run: ./bootstrap.sh --xcode-xip <path> xcode"
        exit 0
    fi
    say "no .xip given; configuring the installed $(basename "$dest")"
fi

DEVELOPER_DIR="$dest/Contents/Developer"
export DEVELOPER_DIR

if is_true "$XCODE_SELECT"; then
    sudo xcode-select -s "$DEVELOPER_DIR"
    ok "xcode-select -> $DEVELOPER_DIR"
fi

step "Xcode license and first launch"
sudo env DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -license accept
sudo env DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -runFirstLaunch
ok "$(xcodebuild -version | tr '\n' ' ')"

step "Simulator runtimes"
for platform in $XCODE_PLATFORMS; do
    case "$platform" in
        iOS)          sdk=iphoneos ;;
        visionOS|xrOS) sdk=xros ;;
        tvOS)         sdk=appletvos ;;
        watchOS)      sdk=watchos ;;
        *) die "unknown platform in XCODE_PLATFORMS: $platform" ;;
    esac
    # "Chosen Runtime" names a SimRuntime only when a runtime matching this
    # Xcode's SDK is installed; otherwise it shows just the SDK build.
    if xcrun simctl runtime match list 2>/dev/null | awk -v sdk="$sdk" '
        $0 ~ "^" sdk "[0-9.]+:$" { inside = 1; next }
        /^[^ ]/                  { inside = 0 }
        inside && /Chosen Runtime:/ && /SimRuntime/ { found = 1 }
        END { exit !found }'; then
        ok "$platform runtime already installed"
    else
        say "Downloading the $platform simulator runtime"
        xcodebuild -downloadPlatform "$platform"
    fi
done

step "Xcode components"
for component in $XCODE_COMPONENTS; do
    if xcodebuild -showComponent "$component" 2>/dev/null | grep -q "Status: installed"; then
        ok "$component already installed"
    else
        say "Downloading $component"
        xcodebuild -downloadComponent "$component"
    fi
done

if [ -n "$xip" ] && is_true "$XCODE_DELETE_XIP"; then
    rm -f "$xip" 2>/dev/null || sudo rm -f "$xip"
    ok "Xcode installed; deleted $xip"
fi

say "UTM's build.yml uses the Actions variable HOST_XCODE_PATH."
say "Make sure it is set to: $dest"
