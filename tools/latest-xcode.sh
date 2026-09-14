#!/bin/bash
#
# Prints the newest Xcode release that runs on a given macOS version, with its
# developer.apple.com download link (sign in with an Apple ID to download).
# Data from https://xcodereleases.com.
#
#   tools/latest-xcode.sh              # for the runner's macOS (asks it over SSH)
#   tools/latest-xcode.sh 15.7.9       # for a specific macOS version
#   tools/latest-xcode.sh --all 26.2   # every compatible release, newest first
#   tools/latest-xcode.sh --beta ...   # include betas and release candidates
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/lib/common.sh"

all=0
beta=0
os=""
for arg in "$@"; do
    case "$arg" in
        --all)  all=1 ;;
        --beta) beta=1 ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
        -*) die "unknown option: $arg" ;;
        *)  os="$arg" ;;
    esac
done

if [ -z "$os" ]; then
    set -a
    . "$ROOT/config.env"
    [ ! -f "$ROOT/config.local.env" ] || . "$ROOT/config.local.env"
    set +a
    [ -n "$RUNNER_HOST" ] || die "RUNNER_HOST is not set in config.local.env; pass a macOS version instead"
    os="$(ssh -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=15 "$ADMIN_USER@$RUNNER_HOST" sw_vers -productVersion)" \
        || die "could not ask $RUNNER_HOST for its macOS version; pass one explicitly"
    say "$RUNNER_HOST runs macOS $os"
fi

curl -fsSL https://xcodereleases.com/data.json | /usr/bin/python3 -c '
import json, sys

os_version, show_all, include_beta = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"

def key(v):
    return tuple(int(p) for p in v.split(".") if p.isdigit())

found = 0
for x in json.load(sys.stdin):
    release = x["version"].get("release", {})
    if not include_beta and not release.get("release"):
        continue
    requires = x.get("requires", "0")
    if key(requires) > key(os_version):
        continue
    url = x.get("links", {}).get("download", {}).get("url", "")
    if "Universal" in url:
        continue  # the Apple silicon archive is smaller; the runner is arm64
    kind = next(iter(release), "release")
    label = "" if kind == "release" else " (%s %s)" % (kind, release[kind] if release[kind] is not True else "")
    d = x["date"]
    print("Xcode %s%s  build %s  %04d-%02d-%02d  requires macOS %s" % (
        x["version"]["number"], label, x["version"]["build"], d["year"], d["month"], d["day"], requires))
    print("  " + url)
    found += 1
    if not show_all:
        break
if not found:
    sys.exit("no Xcode release found for macOS %s" % os_version)
' "$os" "$all" "$beta"

newest="$(curl -fsSL https://xcodereleases.com/data.json | /usr/bin/python3 -c '
import json, sys
for x in json.load(sys.stdin):
    if x["version"].get("release", {}).get("release"):
        print(x["version"]["number"], x.get("requires", "")); break')"
say "Newest Xcode overall: ${newest% *} (requires macOS ${newest#* })"
