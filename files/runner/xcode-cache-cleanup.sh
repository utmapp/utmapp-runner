#!/bin/bash
#
# xcode-cache-cleanup.sh -- purge Xcode / SwiftPM / clang caches for the current user.
#
# Runs weekly from launchd. Before deleting anything it checks whether any of the
# GitHub Actions runners in $RUNNERS_ROOT is in the middle of a build; if one is,
# it waits $RETRY_DELAY and tries again, up to $MAX_ATTEMPTS times.
#
# A runner is "in the middle of a build" when its listener has a Runner.Worker
# child: the worker exists for exactly the lifetime of one job.

set -u

# Resolve the invoking user and their home from the directory service rather than
# from the environment: $HOME survives sudo -u, which would point the cleanup at
# the wrong account.
USER_NAME=$(/usr/bin/id -un)
HOME=$(/usr/bin/dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
if [ -z "${HOME:-}" ] || [ ! -d "$HOME" ]; then
    echo "cannot determine home directory for $USER_NAME" >&2
    exit 1
fi
export HOME

RUNNERS_ROOT="${RUNNERS_ROOT:-$HOME/actions}"
RETRY_DELAY="${RETRY_DELAY:-21600}"   # 6 hours
MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"     # first try + 3 retries == up to 18h of waiting
LOG="${LOG:-$HOME/Library/Logs/xcode-cache-cleanup.log}"
LOCK="${LOCK:-$HOME/Library/Caches/xcode-cache-cleanup.lock}"
LOG_MAX_BYTES=1048576

CACHE_DIR=$(/usr/bin/getconf DARWIN_USER_CACHE_DIR 2>/dev/null)
CACHE_DIR="${CACHE_DIR%/}"

log() {
    printf '%s %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG"
}

rotate_log() {
    if ! /bin/mkdir -p "$(/usr/bin/dirname "$LOG")" || ! /usr/bin/touch "$LOG"; then
        echo "log $LOG is not writable" >&2
        exit 1
    fi
    [ -f "$LOG" ] || return 0
    local size
    size=$(/usr/bin/stat -f %z "$LOG" 2>/dev/null || echo 0)
    [ "$size" -gt "$LOG_MAX_BYTES" ] && /bin/mv -f "$LOG" "$LOG.1"
    return 0
}

# --- single-instance lock -----------------------------------------------------
# launchd already serializes this job, but guard against a manual run overlapping
# with the scheduled one (which can sleep for hours).
acquire_lock() {
    if /bin/mkdir "$LOCK" 2>/dev/null; then
        echo $$ >"$LOCK/pid"
        return 0
    fi
    local other
    other=$(/bin/cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$other" ] && /bin/kill -0 "$other" 2>/dev/null; then
        log "another run is already in progress (pid $other); exiting"
        return 1
    fi
    log "clearing stale lock (pid ${other:-unknown})"
    /bin/rm -rf "$LOCK"
    /bin/mkdir "$LOCK" 2>/dev/null || return 1
    echo $$ >"$LOCK/pid"
}

release_lock() { /bin/rm -rf "$LOCK"; }

# --- runner state -------------------------------------------------------------
# Prints the directory name of every runner that currently has a job executing.
busy_runners() {
    /bin/ps -axo user=,command= | while read -r user cmd; do
        [ "$user" = "$USER_NAME" ] || continue
        case "$cmd" in
            "$RUNNERS_ROOT"/*/bin/Runner.Worker*) ;;
            *) continue ;;
        esac
        cmd=${cmd#"$RUNNERS_ROOT"/}
        printf '%s\n' "${cmd%%/*}"
    done | /usr/bin/sort -u
}

# --- deletion -----------------------------------------------------------------
freed_kib=0

purge() {
    local target=$1 before
    # Only ever delete below the user's home or the per-user darwin cache dir.
    case "$target" in
        "$HOME"/?*) ;;
        "$CACHE_DIR"/?*) [ -n "$CACHE_DIR" ] || { log "REFUSING $target: no cache dir"; return 1; } ;;
        *) log "REFUSING to delete unexpected path: $target"; return 1 ;;
    esac
    if [ ! -e "$target" ]; then
        log "skip (absent): $target"
        return 0
    fi
    before=$(/usr/bin/du -sk "$target" 2>/dev/null | /usr/bin/awk 'NR==1{print $1}')
    before=${before:-0}
    if /bin/rm -rf -- "$target"; then
        log "removed $target (${before} KiB)"
        freed_kib=$(( freed_kib + before ))
    else
        log "FAILED to remove $target"
        return 1
    fi
}

clean() {
    purge "$HOME/Library/Developer/Xcode/DerivedData"
    purge "$HOME/Library/Caches/com.apple.dt.Xcode"
    purge "$HOME/Library/Developer/CoreSimulator/Caches"
    purge "$HOME/Library/Caches/org.swift.swiftpm"
    # ~/Library/org.swift.swiftpm also holds configuration/ and security/, which
    # are settings rather than cache -- take only the cache subdirectory.
    purge "$HOME/Library/org.swift.swiftpm/cache"
    purge "$HOME/.swiftpm/cache"
    purge "$CACHE_DIR/clang"
    purge "$CACHE_DIR/org.llvm.clang"
    purge "$CACHE_DIR/com.apple.DeveloperTools"
}

# --- main ---------------------------------------------------------------------
rotate_log
acquire_lock || exit 0
trap release_lock EXIT INT TERM

log "=== cleanup started for user $USER_NAME (runners: $RUNNERS_ROOT) ==="

attempt=1
while :; do
    busy=$(busy_runners)
    if [ -z "$busy" ]; then
        break
    fi
    log "attempt $attempt/$MAX_ATTEMPTS: builds in progress on: $(echo "$busy" | /usr/bin/tr '\n' ' ')"
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        log "still busy after $MAX_ATTEMPTS attempts; giving up until next week"
        exit 75
    fi
    if [ "$RETRY_DELAY" -ge 3600 ]; then
        log "sleeping $((RETRY_DELAY / 3600))h before retrying"
    else
        log "sleeping ${RETRY_DELAY}s before retrying"
    fi
    /bin/sleep "$RETRY_DELAY"
    attempt=$(( attempt + 1 ))
done

log "all runners idle; purging caches"
clean

# A job could have started while we were deleting. Nothing is corrupted by that
# (the build simply repopulates its cache), but it is worth noting in the log.
late=$(busy_runners)
[ -n "$late" ] && log "note: a build started during cleanup on: $(echo "$late" | /usr/bin/tr '\n' ' ')"

log "=== cleanup finished; freed $(( freed_kib / 1024 )) MiB ==="
exit 0
