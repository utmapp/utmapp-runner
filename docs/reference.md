# Runner reference

What is on the machine after `bootstrap.sh`, where it lives, and why.
Paths assume the defaults in `config.env`.

## Accounts and login

| | |
| --- | --- |
| `administrator` | Provisioned by MacStadium. Admin; owns Homebrew and runs Squid. SSH key login only. |
| `runner` | Standard (non-admin) user. Runs the Actions runners. |
| Automatic login | `runner`. |
| `/etc/sudoers.d/runner` | `administrator ALL=(ALL) NOPASSWD: ALL` and `runner ALL=(ALL) NOPASSWD: /usr/bin/xcode-select` (`build.yml` switches Xcode with `sudo xcode-select -s`). |

**Why automatic login as `runner`.** The runners are LaunchAgents with
`ProcessType Interactive` and `SessionCreate`, the plist GitHub's `svc.sh`
generates. They need a GUI login session for simulators, the keychain and
WindowServer. launchd only loads them once `runner` is logged in. With
automatic login set to `runner`, a reboot brings them back without anyone
opening Screen Sharing.

The account is created without a Secure Token (no `-adminPassword` is passed
to `sysadminctl`). That only matters for FileVault, which a remote machine
can't use.

## Services

| Label | Domain | Runs as | Defined in |
| --- | --- | --- | --- |
| `org.squid-cache.squid` | system (LaunchDaemon) | `administrator` | `squid-patch/deploy.sh --system`, from the launchd plist Homebrew generates (`sh.brew.squid.plist`; `homebrew.mxcl.squid.plist` before Homebrew 7) |
| `org.squid-cache.logrotate` | system (LaunchDaemon) | `administrator` | `squid-patch/org.squid-cache.logrotate.plist` (daily 04:15, `squid -k rotate`) |
| `actions.runner.utmapp.macstadium-N` | `gui/<runner uid>` (LaunchAgent) | `runner` | the runner's `svc.sh install` → `~runner/Library/LaunchAgents/` |
| `local.xcode-cache-cleanup` | `gui/<runner uid>` (LaunchAgent) | `runner` | `files/runner/local.xcode-cache-cleanup.plist` (Sundays 03:15) |
| `com.apple.screensharing` | system | — | enabled by `remote/10-system.sh` |

Squid runs as a LaunchDaemon so it starts at boot. If it were a Homebrew
LaunchAgent, it would need `administrator` to be logged in, and the machine
logs in as `runner`. Squid stays out of `brew services`: restart it with
`sudo launchctl kickstart -k system/org.squid-cache.squid`.

## Squid proxy

Everything about the patch and `squid.conf` is documented in
[`squid-patch/README.md`](../squid-patch/README.md). On the runner:

| Path | |
| --- | --- |
| `/opt/homebrew/etc/squid.conf` | configuration (from `squid-patch/squid.conf`) |
| `/opt/homebrew/etc/squid/squid-self-signed.{key,crt,pem}` | SSL-bump CA, generated on first deploy; **never leaves the machine** |
| `/opt/homebrew/etc/squid/ca-bundle.pem` | Homebrew's public roots plus the CA |
| `/opt/homebrew/etc/squid/github_store_id_helper.py` | store ID helper; runs under `/usr/bin/python3`, so the Command Line Tools or Xcode must be installed |
| `/opt/homebrew/var/cache/squid` | the cache (100 GB) |
| `/opt/homebrew/var/logs/{access,cache}.log` | logs |
| `/opt/homebrew/Library/Taps/osy/homebrew-local/Formula/squid.rb` | the patched formula, pinned |

The CA is restored from `backup.sh`'s copy when there is one. Otherwise a
re-image generates a new CA. The runners find it through the paths in their
`.env`, so nothing else has to change either way.

## GitHub Actions runners

| Path | |
| --- | --- |
| `~runner/actions/runner-N/` | runner N (`config.sh --unattended --replace`, work dir `_work`) |
| `~runner/actions/runner-N/.env` | `files/runner/runner.env` (below) |
| `~runner/actions/runner-N/.path` | `PATH` for the service: Homebrew first, then the system paths |
| `~runner/actions/cleanup.sh` | `ACTIONS_RUNNER_HOOK_JOB_STARTED` / `_COMPLETED`: empties `$GITHUB_WORKSPACE` before and after each job |
| `~runner/Library/Logs/actions.runner.*/` | service stdout/stderr |

Runners are registered to `GITHUB_URL` (`https://github.com/utmapp`) in
group `Default`, with the automatic labels `self-hosted`, `macOS`, `ARM64`
plus `RUNNER_LABELS`. `build.yml` selects them with
`runs-on: ['self-hosted', 'macOS']`. They update themselves.

`.env`:

```
LANG=en_US.UTF-8
http_proxy / https_proxy     = http://127.0.0.1:3128
NODE_EXTRA_CA_CERTS          = squid-self-signed.pem   (Node adds it to its own roots)
SSL_CERT_FILE                = ca-bundle.pem           (these three *replace* the default
REQUESTS_CA_BUNDLE           = ca-bundle.pem            bundle, so they need the public
CURL_CA_BUNDLE               = ca-bundle.pem            roots too; also covers pip)
BOTO_CONFIG, NO_AUTH_BOTO_CONFIG = ~runner/.boto       (gsutil / depot_tools)
ACTIONS_RUNNER_HOOK_JOB_STARTED    = ~runner/actions/cleanup.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED  = ~runner/actions/cleanup.sh
```

## Runner account environment

| File / setting | Content | Why |
| --- | --- | --- |
| `~/.zprofile` | `eval "$(/opt/homebrew/bin/brew shellenv)"` | Homebrew in interactive shells |
| `~/.zshrc` | Homebrew `bison` first in `PATH` | macOS's bison 2.3 is too old for UTM's dependencies |
| `~/.curlrc` | `proxy=127.0.0.1:3128` | curl in build scripts goes through the cache |
| `~/.boto` | proxy + `ca-bundle.pem` | gsutil (depot_tools downloads) through the cache |
| git `cache.cachepath` | `~/.gitcache` | depot_tools git cache |
| git `http.postBuffer` | `157286400` | large pushes/fetches over HTTP |
| git `http.sslVerify` | `false` | carried over from the old machine, where it was set by hand; configurable (`RUNNER_GIT_SSLVERIFY`) |
| pip `--user` (Homebrew python3) | `six pyparsing pyyaml setuptools distlib mako` | same list `build.yml` installs on hosted runners |
| gem `--user-install` (system Ruby) | `xcpretty` | same |

## Homebrew

`files/Brewfile`, installed with `brew bundle --no-upgrade` so a re-run never
upgrades packages under running jobs. It holds the UTM sysroot dependencies
from `build.yml`, `python`, `unxip` (Xcode extraction) and `ncdu`. Squid is
not in it: `squid-patch` builds and pins its own formula.

## Xcode

- `/Applications/Xcode_<version>.app`, selected with `xcode-select`, license accepted, `-runFirstLaunch` done.
- Simulator runtimes for `XCODE_PLATFORMS` (iOS, visionOS): `xcodebuild -downloadPlatform`.
- `XCODE_COMPONENTS` (MetalToolchain, needed since Xcode 26): `xcodebuild -downloadComponent`.
- `build.yml` uses `vars.HOST_XCODE_PATH`; keep that variable pointing at the installed app.

Apple has no unattended Xcode download (developer.apple.com needs an Apple ID
with 2FA), so you download the `.xip` yourself. `bootstrap.sh` uploads it
(`--xcode-xip`), uses one already on the runner (`--xcode-xip-on-runner` /
`XCODE_XIP_ON_RUNNER`), or fetches one from `XCODE_XIP_URL`, for example a
pre-signed bucket URL. With `XCODE_DELETE_XIP=1` (the default) the `.xip` is
deleted once the whole xcode step has succeeded.

## Machine settings

| Setting | Value | Where |
| --- | --- | --- |
| Power | `sleep 0`, `displaysleep 0`, `autorestart 1`, `womp 1`, restart on freeze | always |
| Spotlight | indexing off on all volumes | `DISABLE_SPOTLIGHT` |
| Software update | automatic check/download/install, critical updates | `SOFTWARE_UPDATE_*` |
| Screen sharing | on | `SCREEN_SHARING` |
| Guest account | off | always |
| sshd | `/etc/ssh/sshd_config.d/010-ci-runner.conf`: no passwords, no keyboard-interactive, no root | `SSH_DISABLE_PASSWORD_AUTH` |
| Firewall | off (macOS default, left alone) | — |
