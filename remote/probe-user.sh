#!/bin/bash
#
# For bootstrap.sh, before it asks for passwords: prints "user-exists" if
# RUNNER_USER exists and "autologin-ok" if automatic login as AUTOLOGIN_USER
# would actually work.

. "$(dirname "$0")/../lib/remote.sh"
if id "$RUNNER_USER" >/dev/null 2>&1; then echo user-exists; fi
if [ -n "$AUTOLOGIN_USER" ] && autologin_works "$AUTOLOGIN_USER"; then echo autologin-ok; fi
true
