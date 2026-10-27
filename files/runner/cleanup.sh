#!/bin/sh
#
# ACTIONS_RUNNER_HOOK_JOB_STARTED and _COMPLETED hook (see runner.env): empty the
# workspace when a job finishes, so idle runners don't hold a checkout on disk,
# and again when one starts, in case the previous job died before its hook ran.
#
# Also drop the DerivedData folders of projects inside the workspace. Xcode names
# them after the project's path, so every runner x platform x dependency gets its
# own, and a fresh checkout never reuses them. The shared module caches
# (ModuleCache.noindex etc.) have no WorkspacePath and are left alone; other
# runners' folders are never under this workspace. Finally, clear xcrun's cache.

[ -n "$GITHUB_WORKSPACE" ] || exit 0

if [ -d "$GITHUB_WORKSPACE" ]; then
    echo "Cleaning up workspace..."
    rm -rf "$GITHUB_WORKSPACE"
    mkdir "$GITHUB_WORKSPACE"
fi

derived="$HOME/Library/Developer/Xcode/DerivedData"
for dir in "$derived"/*/; do
    [ -f "$dir/info.plist" ] || continue
    ws=$(/usr/libexec/PlistBuddy -c "Print :WorkspacePath" "$dir/info.plist" 2>/dev/null) || continue
    case "$ws" in
        "$GITHUB_WORKSPACE"/*)
            echo "Removing DerivedData for $ws"
            rm -rf "$dir"
            ;;
    esac
done

# Also drop xcrun's lookup cache, which can pin a tool to a stale path (e.g.
# Xcode's metal stub from before the Metal toolchain was installed).
rm -f "$(getconf DARWIN_USER_TEMP_DIR)/xcrun_db"
exit 0
