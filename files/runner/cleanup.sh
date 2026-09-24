#!/bin/sh
#
# ACTIONS_RUNNER_HOOK_JOB_STARTED and _COMPLETED hook (see runner.env): empty the
# workspace when a job finishes, so idle runners don't hold a checkout on disk,
# and again when one starts, in case the previous job died before its hook ran.

if [ -d "$GITHUB_WORKSPACE" ]; then
    echo "Cleaning up workspace..."
    rm -rf "$GITHUB_WORKSPACE"
    mkdir "$GITHUB_WORKSPACE"
fi
