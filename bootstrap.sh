#!/bin/bash
#
# Rebuilds the macOS CI runner over SSH after a re-image. Run it on your own
# Mac from a checkout of this repository (with submodules):
#
#   ./bootstrap.sh --xcode-xip ~/Downloads/Xcode_26.3_Apple_silicon.xip
#
# Settings come from config.env (and config.local.env, if present). Secrets
# are never committed. If backup.sh has saved the runner's secrets into
# SECRETS_DIR, they are restored from there: SSH host keys, the Squid CA,
# runner registrations and the automatic login password. Anything else is
# generated, read from the environment or asked for:
#
#   RUNNER_USER_PASSWORD   password for the runner account (created, and used
#                          for automatic login)
#   AUTOLOGIN_PASSWORD     only if AUTOLOGIN_USER is not RUNNER_USER
#   GITHUB_RUNNER_TOKEN    runner registration token; otherwise created with
#                          the gh CLI (needs admin:org) or asked for
#
# Usage: ./bootstrap.sh [options] [step ...]
#
#   --xcode-xip PATH        upload and install this Xcode .xip
#   --xcode-xip-on-runner PATH
#                           install an Xcode .xip that is already on the runner
#                           (absolute, or relative to the admin user's home)
#   --reboot                reboot without asking if the runner session is missing
#   --no-reboot             never reboot
#   --reconfigure-runners   re-register runners that are already registered
#   --no-restore            ignore the backup in SECRETS_DIR (see backup.sh)
#   --skip STEP[,STEP]      run every selected step except these (e.g. --skip clt)
#   --list                  list the steps and exit
#   -h, --help              show this help
#
# With no steps, all of them run in order. Every step is safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/common.sh"
. "$ROOT/lib/local.sh"

STEPS="keys sudo system clt homebrew squid user runners maintenance xcode activate verify"

describe() {
    case "$1" in
        keys)        echo "make sure key-based SSH login works (installs your public key)" ;;
        sudo)        echo "passwordless sudo for the admin account" ;;
        system)      echo "power, Spotlight, updates, screen sharing, sshd" ;;
        clt)         echo "install/update the Command Line Tools (slow; reinstalls every time)" ;;
        homebrew)    echo "Homebrew and files/Brewfile" ;;
        squid)       echo "patched Squid proxy from the squid-patch submodule" ;;
        user)        echo "runner account, automatic login, dotfiles, pip and gem packages" ;;
        runners)     echo "download, register and install the GitHub Actions runners" ;;
        maintenance) echo "weekly Xcode cache cleanup" ;;
        xcode)       echo "install Xcode from a .xip, runtimes and components" ;;
        activate)    echo "start the runner LaunchAgents (reboots into autologin if needed)" ;;
        verify)      echo "read-only health check" ;;
    esac
}

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; }

# ---------------------------------------------------------------- arguments --

opt_xip=""
opt_xip_on_runner=""
opt_reboot=""
opt_reconfigure=0
opt_restore=1
selected=""
skipped=""
while [ $# -gt 0 ]; do
    case "$1" in
        --xcode-xip)           [ $# -ge 2 ] || die "--xcode-xip needs a path"; opt_xip="$2"; shift ;;
        --xcode-xip=*)         opt_xip="${1#*=}" ;;
        --xcode-xip-on-runner) [ $# -ge 2 ] || die "--xcode-xip-on-runner needs a path"; opt_xip_on_runner="$2"; shift ;;
        --xcode-xip-on-runner=*) opt_xip_on_runner="${1#*=}" ;;
        --reboot)              opt_reboot=yes ;;
        --no-reboot)           opt_reboot=no ;;
        --reconfigure-runners) opt_reconfigure=1 ;;
        --no-restore)          opt_restore=0 ;;
        --skip)                [ $# -ge 2 ] || die "--skip needs a step"; skipped="$skipped ${2//,/ }"; shift ;;
        --skip=*)              v="${1#*=}"; skipped="$skipped ${v//,/ }" ;;
        --list)                for s in $STEPS; do printf '  %-12s %s\n' "$s" "$(describe "$s")"; done; exit 0 ;;
        -h|--help)             usage; exit 0 ;;
        -*)                    die "unknown option: $1 (try --help)" ;;
        *)
            case " $STEPS " in *" $1 "*) ;; *) die "unknown step: $1 (try --list)" ;; esac
            selected="$selected $1" ;;
    esac
    shift
done
[ -n "$selected" ] || selected="$STEPS"
for s in $skipped; do
    case " $STEPS " in *" $s "*) ;; *) die "unknown step for --skip: $s (try --list)" ;; esac
done
selected=" $selected "
for s in $skipped; do selected="${selected/ $s / }"; done
wants() { case "$selected" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ------------------------------------------------------------------- config --

load_config
[ -z "$opt_xip" ] || XCODE_XIP="$opt_xip"
[ -z "$opt_xip_on_runner" ] || XCODE_XIP_ON_RUNNER="$opt_xip_on_runner"
[ -z "$opt_xip" ] || [ -z "$opt_xip_on_runner" ] \
    || die "--xcode-xip and --xcode-xip-on-runner are mutually exclusive"

[ -f "$ROOT/squid-patch/deploy.sh" ] \
    || die "squid-patch submodule is missing; run: git submodule update --init"
if [ -n "$XCODE_XIP" ]; then
    [ -f "$XCODE_XIP" ] || die "Xcode .xip not found: $XCODE_XIP"
fi

restore=0
if [ "$opt_restore" = 1 ] && [ -d "$SECRETS_PATH" ]; then
    restore=1
fi

setup_ssh

# ------------------------------------------------------------------ secrets --

prompt_secret() {  # prompt_secret <prompt> <confirm 0|1> -> stdout
    local a b
    [ -t 0 ] || die "cannot prompt for a secret without a terminal (set it in the environment)"
    while :; do
        read -r -s -p "$1: " a </dev/tty; echo >&2
        [ -n "$a" ] || { warn "empty; try again"; continue; }
        [ "$2" = 1 ] || { printf '%s' "$a"; return; }
        read -r -s -p "Again: " b </dev/tty; echo >&2
        [ "$a" = "$b" ] && { printf '%s' "$a"; return; }
        warn "did not match; try again"
    done
}

# backup_autologin_password <user>: the password stored in the backup's
# /etc/kcpassword, if the backed-up machine logged in automatically as <user>.
backup_autologin_password() {
    local dir="$SECRETS_PATH/autologin"
    [ "$restore" = 1 ] && [ -f "$dir/kcpassword" ] && [ "$(cat "$dir/user" 2>/dev/null)" = "$1" ] || return 0
    kcpassword_decode < "$dir/kcpassword"
}

runner_password=""
autologin_password=""
collect_user_secrets() {
    local probe user_exists autologin_ok
    probe="$(run_remote probe-user.sh </dev/null)"
    case "$probe" in *user-exists*) user_exists=1 ;; *) user_exists=0 ;; esac
    case "$probe" in *autologin-ok*) autologin_ok=1 ;; *) autologin_ok=0 ;; esac
    [ -n "$AUTOLOGIN_USER" ] || autologin_ok=1

    local backup_password
    backup_password="$(backup_autologin_password "$RUNNER_USER")"

    if [ "$user_exists" = 0 ] || { [ "$autologin_ok" = 0 ] && [ "$AUTOLOGIN_USER" = "$RUNNER_USER" ]; }; then
        runner_password="${RUNNER_USER_PASSWORD:-$backup_password}"
        [ -z "$backup_password" ] || [ -n "${RUNNER_USER_PASSWORD:-}" ] \
            || ok "using the '$RUNNER_USER' password from $SECRETS_DIR/autologin"
        if [ -z "$runner_password" ]; then
            if [ "$user_exists" = 0 ]; then
                runner_password="$(prompt_secret "New password for the '$RUNNER_USER' account" 1)"
            else
                runner_password="$(prompt_secret "Password of the existing '$RUNNER_USER' account (for automatic login)" 0)"
            fi
        fi
    fi
    if [ "$autologin_ok" = 0 ]; then
        if [ "$AUTOLOGIN_USER" = "$RUNNER_USER" ]; then
            autologin_password="$runner_password"
        else
            autologin_password="${AUTOLOGIN_PASSWORD:-$(backup_autologin_password "$AUTOLOGIN_USER")}"
            [ -n "$autologin_password" ] \
                || autologin_password="$(prompt_secret "Password of '$AUTOLOGIN_USER' (for automatic login)" 0)"
        fi
    fi
}

# Organization or repository API path for GITHUB_URL.
github_api_scope() {
    local path="${GITHUB_URL#https://github.com/}"
    path="${path%/}"
    case "$path" in
        */*) echo "repos/$path" ;;
        *)   echo "orgs/$path" ;;
    esac
}

runner_token="${GITHUB_RUNNER_TOKEN:-}"
runners_need_token() {
    [ "$opt_reconfigure" = 1 ] && return 0
    local missing i
    missing="$(rssh "
        home=\$(dscl . -read /Users/$(printf '%q' "$RUNNER_USER") NFSHomeDirectory 2>/dev/null | awk '{print \$2}')
        i=1
        while [ \$i -le $RUNNER_COUNT ]; do
            [ -n \"\$home\" ] && sudo test -f \"\$home/$RUNNERS_DIR/runner-\$i/.runner\" || echo \$i
            i=\$((i + 1))
        done")"
    for i in $missing; do
        if [ "$restore" = 1 ] && runner_backup_matches "$SECRETS_PATH/runners/runner-$i" "${RUNNER_NAME_PREFIX}-${i}"; then
            continue
        fi
        return 0
    done
    return 1
}
collect_runner_token() {
    [ -z "$runner_token" ] || return 0
    if command -v gh >/dev/null 2>&1; then
        runner_token="$(gh api -X POST "$(github_api_scope)/actions/runners/registration-token" --jq .token 2>/dev/null || true)"
        [ -z "$runner_token" ] || { ok "registration token created with gh"; return 0; }
    fi
    say "Create a registration token (valid 1 hour): 'New runner' on the runner settings page of $GITHUB_URL,"
    say "or: gh api -X POST $(github_api_scope)/actions/runners/registration-token --jq .token"
    runner_token="$(prompt_secret "Runner registration token" 0)"
}

# ---------------------------------------------------------------- host keys --

# True when the backup has SSH host keys that differ from the runner's current
# ones, i.e. the system step is about to put the old keys back.
host_keys_will_change() {
    [ "$restore" = 1 ] && ls "$SECRETS_PATH"/ssh/ssh_host_*_key.pub >/dev/null 2>&1 || return 1
    [ "$(cat "$SECRETS_PATH"/ssh/ssh_host_*_key.pub | cut -d' ' -f1,2 | sort)" \
        != "$(rssh 'cat /etc/ssh/ssh_host_*_key.pub' | cut -d' ' -f1,2 | sort)" ]
}

# After the old host keys are restored, known_hosts still has the keys the
# re-image generated: replace them with the restored ones.
trust_restored_host_keys() {
    local host alias pattern pub
    host="$(ssh -G "${SSH_OPTS[@]}" "$TARGET" | awk '$1 == "hostname" {print $2}')"
    alias="$(ssh -G "${SSH_OPTS[@]}" "$TARGET" | awk '$1 == "hostkeyalias" {print $2}')"
    [ -z "$alias" ] || host="$alias"
    pattern="$host"
    [ "$SSH_PORT" = 22 ] || pattern="[$host]:$SSH_PORT"
    ssh-keygen -R "$pattern" >/dev/null 2>&1 || true
    [ "$pattern" = "$RUNNER_HOST" ] || [ "$SSH_PORT" != 22 ] || ssh-keygen -R "$RUNNER_HOST" >/dev/null 2>&1 || true
    for pub in "$SECRETS_PATH"/ssh/ssh_host_*_key.pub; do
        echo "$pattern $(cut -d' ' -f1,2 "$pub")" >> "$HOME/.ssh/known_hosts"
    done
    ssh "${SSH_OPTS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true
    connect_check >/dev/null || die "cannot connect after restoring the SSH host keys"
    ok "known_hosts now trusts the restored host keys for $pattern"
}

# ------------------------------------------------------------------- reboot --

decide_reboot() {
    [ -z "$opt_reboot" ] || return 0
    if [ -t 0 ]; then
        local answer
        read -r -p "Reboot the runner at the end if its '$RUNNER_USER' session is not running yet? [Y/n] " answer </dev/tty
        case "$answer" in [nN]*) opt_reboot=no ;; *) opt_reboot=yes ;; esac
    else
        opt_reboot=no
    fi
}

reboot_and_wait() {
    step "Rebooting $RUNNER_HOST"
    rssh "sudo shutdown -r now" >/dev/null 2>&1 || true
    ssh "${SSH_OPTS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true
    sleep 30
    local deadline=$((SECONDS + 900))
    until connect_check >/dev/null; do
        [ $SECONDS -lt $deadline ] || die "runner did not come back within 15 minutes"
        sleep 10
    done
    ok "SSH is back"
    deadline=$((SECONDS + 300))
    until rssh "sudo launchctl print gui/\$(id -u $(printf '%q' "$RUNNER_USER")) >/dev/null 2>&1"; do
        [ $SECONDS -lt $deadline ] || { warn "no GUI session for $RUNNER_USER after boot; check automatic login"; return 1; }
        sleep 10
    done
    ok "$RUNNER_USER is logged in"
}

# --------------------------------------------------------------------- main --

started=$SECONDS
say "Runner: $TARGET   steps:$selected"
if [ "$restore" = 1 ]; then
    say "Restoring secrets from $SECRETS_DIR/ where present ($(sed -n 2p "$SECRETS_PATH/manifest.txt" 2>/dev/null))"
fi

# Always: without key login nothing else can run unattended.
do_keys
# Secrets only travel to the runner when a step that restores them runs, and
# are deleted from its staging directory on exit.
if [ "$restore" = 1 ] && { wants system || wants squid || wants runners; }; then
    upload with-secrets
else
    upload
fi

if wants sudo; then
    if [ -t 0 ]; then
        ssh "${SSH_OPTS[@]}" -t "$TARGET" "cd ~ && bash $(printf '%q' "$REMOTE_STAGING_DIR/remote/00-sudoers.sh")"
    else
        run_remote 00-sudoers.sh </dev/null
    fi
fi
require_sudo

# Ask for everything up front so the long steps run unattended.
if wants user; then collect_user_secrets; fi
if wants runners && runners_need_token; then collect_runner_token; fi
if wants activate; then decide_reboot; fi
# A missing .xip on the runner should fail now, not after an hour of other steps.
if wants xcode && [ -z "$XCODE_XIP" ] && [ -n "$XCODE_XIP_ON_RUNNER" ]; then
    rssh "cd ~ && test -f $(printf '%q' "${XCODE_XIP_ON_RUNNER/#\~\//}")" \
        || die "Xcode .xip not found on the runner: $XCODE_XIP_ON_RUNNER"
fi

for s in $STEPS; do
    wants "$s" || continue
    case "$s" in
        keys|sudo) ;;
        system)
            if host_keys_will_change; then
                run_remote 10-system.sh </dev/null
                trust_restored_host_keys
            else
                run_remote 10-system.sh </dev/null
            fi ;;
        clt)         run_remote 15-command-line-tools.sh </dev/null ;;
        homebrew)    run_remote 20-homebrew.sh </dev/null ;;
        squid)       run_remote 30-squid.sh </dev/null ;;
        user)        printf '%s\n%s\n' "$runner_password" "$autologin_password" | run_remote 40-runner-user.sh ;;
        runners)     printf '%s\n' "$runner_token" | run_remote 60-actions-runners.sh "RUNNER_RECONFIGURE=$opt_reconfigure" ;;
        maintenance) run_remote 70-maintenance.sh </dev/null ;;
        xcode)
            if [ -n "$XCODE_XIP" ]; then
                step "Uploading $(basename "$XCODE_XIP")"
                remote_home="$(rssh 'printf %s "$HOME"')"
                remote_xip="$remote_home/Downloads/$(basename "$XCODE_XIP")"
                rssh "mkdir -p ~/Downloads"
                # --partial: a multi-GB upload that drops can resume on re-run.
                if ! rsync --partial --progress -e "ssh ${SSH_OPTS[*]}" \
                        "$XCODE_XIP" "$TARGET:$(printf '%q' "$remote_xip")"; then
                    warn "rsync failed; retrying with scp (starts over)"
                    scp -P "$SSH_PORT" -o "ControlPath=$CONTROL_DIR/%C" \
                        "$XCODE_XIP" "$TARGET:$(printf '%q' "$remote_xip")"
                fi
                run_remote 50-xcode.sh "XCODE_XIP_REMOTE=$remote_xip" </dev/null
            elif [ -n "$XCODE_XIP_ON_RUNNER" ]; then
                run_remote 50-xcode.sh "XCODE_XIP_REMOTE=$XCODE_XIP_ON_RUNNER" </dev/null
            else
                run_remote 50-xcode.sh </dev/null
            fi ;;
        activate)
            rc=0
            run_remote 80-activate.sh </dev/null || rc=$?
            if [ "$rc" = 3 ]; then
                if [ "$opt_reboot" = yes ]; then
                    reboot_and_wait && run_remote 80-activate.sh </dev/null
                else
                    warn "not rebooting; the runners start at the next boot (or run: ./bootstrap.sh --reboot activate verify)"
                fi
            elif [ "$rc" != 0 ]; then
                exit "$rc"
            fi ;;
        verify)      run_remote 90-verify.sh </dev/null ;;
    esac
done

elapsed=$((SECONDS - started))
printf '\n\033[1;32mDone\033[0m in %dm%02ds.\n' $((elapsed / 60)) $((elapsed % 60))
