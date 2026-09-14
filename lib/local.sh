# Sourced by the scripts you run on your own Mac (bootstrap.sh, backup.sh):
# configuration, SSH to the runner, and uploading the setup files.
#
# Expects ROOT (the repository) to be set and lib/common.sh to be sourced.

# ------------------------------------------------------------------- config --

load_config() {
    [ -f "$ROOT/config.env" ] || die "config.env not found"
    set -a
    . "$ROOT/config.env"
    [ ! -f "$ROOT/config.local.env" ] || . "$ROOT/config.local.env"
    set +a
    SECRETS_PATH="$ROOT/$SECRETS_DIR"
    [ -n "$RUNNER_HOST" ] || die "RUNNER_HOST is not set; put RUNNER_HOST=\"<address>\" in config.local.env"
}

# ---------------------------------------------------------------------- ssh --

setup_ssh() {
    TARGET="$ADMIN_USER@$RUNNER_HOST"
    CONTROL_DIR="$(mktemp -d /tmp/runner-ssh.XXXXXX)"   # short path: sockets are limited to 104 bytes
    SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
              -o ControlMaster=auto -o "ControlPath=$CONTROL_DIR/%C" -o ControlPersist=600)
    trap cleanup_ssh EXIT
}

# Removes restored secrets from the runner's staging directory (they have been
# installed where they belong by then) and closes the shared connection.
cleanup_ssh() {
    if [ "${REMOTE_SECRETS_UPLOADED:-0}" = 1 ]; then
        ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" \
            "rm -rf ~/$(printf '%q' "$REMOTE_STAGING_DIR")/secrets" >/dev/null 2>&1 \
            || warn "could not remove ~/$REMOTE_STAGING_DIR/secrets from the runner; delete it by hand"
    fi
    ssh "${SSH_OPTS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true
    rm -rf "$CONTROL_DIR"
}

rssh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

# run_remote <script> [NAME=value ...]: runs remote/<script> on the runner with
# the given environment. Its stdin and stdout are this script's, so callers
# can pipe secrets in and data out.
run_remote() {
    local script="$1" envs="" kv
    shift
    for kv in "$@"; do envs="$envs $(printf '%q' "$kv")"; done
    rssh "cd ~ && env$envs bash $(printf '%q' "$REMOTE_STAGING_DIR/remote/$script")"
}

connect_check() {  # prints ssh's error output on failure
    ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET" true 2>&1 >/dev/null
}

do_keys() {
    step "SSH keys ($TARGET)"
    local err
    if err="$(connect_check)"; then
        ok "key login works"
        return
    fi
    case "$err" in
        *"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
            die "the runner's host key changed (expected after a re-image). If that is why, run: ssh-keygen -R $RUNNER_HOST" ;;
        *"Permission denied"*) ;;
        *) die "cannot reach $TARGET: $err" ;;
    esac
    [ -f "$SSH_PUBLIC_KEY_FILE" ] || die "SSH_PUBLIC_KEY_FILE not found: $SSH_PUBLIC_KEY_FILE"
    say "Installing $SSH_PUBLIC_KEY_FILE; enter $ADMIN_USER's password when asked"
    ssh-copy-id -i "$SSH_PUBLIC_KEY_FILE" -p "$SSH_PORT" -o ControlMaster=no -o ControlPath=none "$TARGET"
    connect_check >/dev/null || die "key login still fails after ssh-copy-id"
    ok "key login works"
}

require_sudo() {
    rssh "sudo -n true" 2>/dev/null || die "passwordless sudo is not set up on the runner; run: ./bootstrap.sh sudo"
}

# upload [with-secrets]: copies lib/, remote/, files/, squid-patch/ and the
# resolved configuration to ~/REMOTE_STAGING_DIR on the runner (cache/ there
# is kept). With "with-secrets", the backup in SECRETS_DIR goes along as
# secrets/, minus the automatic login password, which is only used locally.
upload() {
    step "Uploading setup files to $TARGET:~/$REMOTE_STAGING_DIR"
    local stage name keys
    stage="$(mktemp -d)"
    mkdir -p "$stage/files"
    cp -R "$ROOT/lib" "$ROOT/remote" "$stage/"
    cp -R "$ROOT/files/" "$stage/files/"
    rsync -a --exclude .git "$ROOT/squid-patch/" "$stage/squid-patch/"

    keys="$stage/files/authorized_keys"
    if [ -n "$SSH_AUTHORIZED_KEYS_FILE" ]; then
        [ -f "$ROOT/$SSH_AUTHORIZED_KEYS_FILE" ] || die "SSH_AUTHORIZED_KEYS_FILE not found: $SSH_AUTHORIZED_KEYS_FILE"
        cat "$ROOT/$SSH_AUTHORIZED_KEYS_FILE" >> "$keys"
    fi

    if [ "${1:-}" = with-secrets ] && [ -d "$SECRETS_PATH" ]; then
        (umask 077 && mkdir "$stage/secrets" && rsync -a --exclude autologin "$SECRETS_PATH/" "$stage/secrets/")
        [ ! -f "$SECRETS_PATH/ssh/authorized_keys" ] || cat "$SECRETS_PATH/ssh/authorized_keys" >> "$keys"
        REMOTE_SECRETS_UPLOADED=1
        say "including the backup from $SECRETS_DIR/"
    fi

    {
        echo "# Generated from config.env$( [ -f "$ROOT/config.local.env" ] && echo " and config.local.env"). Do not edit."
        for name in $(config_names "$ROOT/config.env" "$ROOT/config.local.env"); do
            printf '%s=%q\n' "$name" "${!name}"
        done
    } > "$stage/config.resolved.env"

    COPYFILE_DISABLE=1 tar -C "$stage" -czf - . | rssh "
        set -e
        dir=\$HOME/$(printf '%q' "$REMOTE_STAGING_DIR")
        mkdir -p \"\$dir\"
        cd \"\$dir\"
        rm -rf lib remote files squid-patch secrets config.resolved.env
        tar -xzf -
        chmod 755 \"\$dir\"
        [ ! -d secrets ] || chmod -R go-rwx secrets
    "
    rm -rf "$stage"
    ok "uploaded"
}
