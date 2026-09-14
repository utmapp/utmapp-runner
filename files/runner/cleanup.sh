#!/bin/sh
#
# ACTIONS_RUNNER_HOOK_JOB_STARTED hook (see runner.env): start every job with an
# empty workspace, since self-hosted runners keep the previous job's checkout.

if [ -d "$GITHUB_WORKSPACE" ]; then
    echo "Cleaning up workspace..."
    rm -rf "$GITHUB_WORKSPACE"
    mkdir "$GITHUB_WORKSPACE"
fi
