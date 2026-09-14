#!/bin/bash
#
# Pulls the runner's secrets into SECRETS_DIR (default: secrets/), a
# git-ignored directory in this repository, so a re-image can put them back
# instead of generating new ones:
#
#   ssh/        sshd host keys (no "host key changed" after a re-image)
#               and the admin account's authorized_keys
#   squid/      the SSL-bump CA and DH parameters
#   runners/    each runner's registration (.runner, .credentials*), so
#               runners reconnect as themselves without a registration token
#   autologin/  /etc/kcpassword: the automatic login password, recoverable
#
# bootstrap.sh uses whatever is there automatically (see --no-restore).
# Read-only on the runner. A previous backup is kept as SECRETS_DIR.<timestamp>.
#
# Usage: ./backup.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/local.sh"

case "${1:-}" in
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    "") ;;
    *) die "unknown argument: $1 (try --help)" ;;
esac

load_config

# ------------------------------------------------------------ never commit --

case "$SECRETS_DIR" in
    ""|/*|*..*) die "SECRETS_DIR must be a path inside the repository" ;;
esac
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" check-ignore -q "$SECRETS_DIR/probe" \
        || die "$SECRETS_DIR/ is not git-ignored; add it to .gitignore before backing up secrets into it"
    git -C "$ROOT" check-ignore -q "$SECRETS_DIR.backup/probe" \
        || die "$SECRETS_DIR.*/ (previous backups) is not git-ignored; add it to .gitignore"
    [ -z "$(git -C "$ROOT" ls-files -- "$SECRETS_DIR" "$SECRETS_DIR.*")" ] \
        || die "files under $SECRETS_DIR are tracked by git; remove them from the index (git rm --cached) first"
else
    warn "$ROOT is not a git checkout; cannot confirm $SECRETS_DIR/ is ignored"
fi

# -------------------------------------------------------------------- pull --

setup_ssh
say "Backing up secrets from $TARGET into $SECRETS_DIR/"
do_keys
upload
require_sudo

umask 077
incoming="$(mktemp -d "$SECRETS_PATH.incoming.XXXXXX")"   # matches the ignored SECRETS_DIR.*/
trap 'rm -rf "$incoming"; cleanup_ssh' EXIT

step "Collecting"
run_remote backup-export.sh </dev/null | tar -xzf - -C "$incoming"
[ -f "$incoming/manifest.txt" ] || die "the runner sent an incomplete backup"
chmod -R go-rwx "$incoming"

# Sanity checks, so a broken backup is noticed now rather than after a re-image.
step "Checking"
if [ -f "$incoming/squid/squid-self-signed.key" ]; then
    [ "$(openssl x509 -in "$incoming/squid/squid-self-signed.crt" -noout -pubkey | shasum)" \
        = "$(openssl pkey -in "$incoming/squid/squid-self-signed.key" -pubout | shasum)" ] \
        && ok "Squid CA key matches its certificate ($(openssl x509 -in "$incoming/squid/squid-self-signed.crt" -noout -enddate))" \
        || warn "Squid CA key does not match its certificate"
else
    warn "no Squid CA on the runner"
fi
for key in "$incoming"/ssh/ssh_host_*_key; do
    [ -f "$key" ] || continue
    [ "$(ssh-keygen -y -f "$key" 2>/dev/null | cut -d' ' -f1,2)" = "$(cut -d' ' -f1,2 "$key.pub")" ] \
        && ok "$(basename "$key") matches its public key" \
        || warn "$(basename "$key") does not match its public key"
done
for dir in "$incoming"/runners/runner-*; do
    [ -d "$dir" ] || continue
    n="${dir##*-}"
    if runner_backup_matches "$dir" "${RUNNER_NAME_PREFIX}-${n}"; then
        ok "$(basename "$dir"): $(runner_json "$dir/.runner" agentName) registered to $(runner_json "$dir/.runner" gitHubUrl)"
    else
        warn "$(basename "$dir"): $(runner_json "$dir/.runner" agentName) does not match ${RUNNER_NAME_PREFIX}-${n} at $GITHUB_URL; bootstrap will not restore it"
    fi
done
if [ -f "$incoming/autologin/user" ]; then
    ok "automatic login password for '$(cat "$incoming/autologin/user")'"
    [ "$(cat "$incoming/autologin/user")" = "$AUTOLOGIN_USER" ] \
        || warn "the runner logs in as '$(cat "$incoming/autologin/user")', not AUTOLOGIN_USER=$AUTOLOGIN_USER; that password will not be used for '$AUTOLOGIN_USER'"
fi

# ------------------------------------------------------------------- store --

if [ -d "$SECRETS_PATH" ]; then
    if diff -rq -x manifest.txt "$SECRETS_PATH" "$incoming" >/dev/null 2>&1; then
        rm -rf "$incoming"
        ok "nothing changed since the last backup; $SECRETS_DIR/ left as is"
        exit 0
    fi
    previous="$SECRETS_PATH.$(date +%Y%m%d%H%M%S)"
    mv "$SECRETS_PATH" "$previous"
    say "previous backup moved to $(basename "$previous")/"
fi
mkdir -p "$(dirname "$SECRETS_PATH")"
mv "$incoming" "$SECRETS_PATH"
chmod 700 "$SECRETS_PATH"

step "Saved"
sed -n '1,2p' "$SECRETS_PATH/manifest.txt"
(cd "$SECRETS_PATH" && find . -type f ! -name manifest.txt | sed 's|^\./|  |' | sort)
say "Keep a copy somewhere safe outside this machine too (a password manager or encrypted disk)."
