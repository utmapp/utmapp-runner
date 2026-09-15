# utmapp-runner

Scripts, configuration and docs to rebuild UTM's self-hosted macOS CI runner
(a MacStadium Mac mini) from a fresh re-image, over SSH, in one command.

What ends up on the machine:

- **Four GitHub Actions runners** (`macstadium-1` … `macstadium-4`, org `utmapp`).
  They run as the unprivileged `runner` account, as LaunchAgents in its
  auto-logged-in GUI session.
- **A patched Squid caching proxy** from the [`squid-patch`](squid-patch/) submodule.
  It caches `actions/cache` blobs and release assets behind SSL bumping, and
  runs at boot as a LaunchDaemon.
- **Xcode** from a `.xip` you provide, plus simulator runtimes and the Metal toolchain.
- **Homebrew build dependencies**, Python/Ruby packages, a weekly Xcode cache
  cleanup, and machine settings (no sleep, no Spotlight, key-only SSH). The
  network is expected to be provisioned already.

See [docs/reference.md](docs/reference.md) for every file and setting and why
it's there, and [docs/operations.md](docs/operations.md) for day-to-day tasks.

## Before a re-image: back up the secrets

```sh
./backup.sh
```

This pulls the machine's secrets into `secrets/`, which is git-ignored. The
script refuses to run if that directory isn't ignored. It pulls the SSH host
keys, the admin `authorized_keys`, the Squid CA, every runner's registration
(`.runner`, `.credentials*`) and the automatic login password
(`/etc/kcpassword`). It only reads from the machine. An older backup is kept as
`secrets.<timestamp>/`. Keep a copy somewhere safe outside your laptop too.

`bootstrap.sh` then restores whatever is in `secrets/` instead of making new
ones, unless you pass `--no-restore`:

| From the backup | Effect |
| --- | --- |
| SSH host keys | the machine keeps its identity; `bootstrap.sh` updates your `known_hosts` after the `system` step |
| Squid CA | same CA as before (anything that trusted it still does) |
| runner registrations | `macstadium-N` reconnect as the same runners, **no registration token needed** |
| automatic login password | used as the `runner` password when the backup's machine logged in as `runner` |

Registrations only restore when the name and `GITHUB_URL` match. GitHub
removes self-hosted runners that stay offline for about 14 days. If a restored
runner can't connect, register it again with
`./bootstrap.sh --reconfigure-runners runners activate verify`.

## Quick start (after a re-image)

On your own Mac:

```sh
git clone --recurse-submodules <this repo> utmapp-runner
cd utmapp-runner

# 1. Point the scripts at the machine (config.local.env is git-ignored), and
#    check config.env (accounts, runner count, ...):
echo 'RUNNER_HOST="<runner address>"' >> config.local.env

# 2. The re-image gave the machine new SSH host keys. (With a backup, the old
#    keys are put back and known_hosts is updated again later.)
ssh-keygen -R "<runner address>"

# 3. Download Xcode. This prints the newest version the runner's macOS
#    supports and its developer.apple.com link (needs an Apple ID sign-in):
tools/latest-xcode.sh

# 4. Run everything:
./bootstrap.sh --xcode-xip ~/Downloads/Xcode_26.3_Apple_silicon.xip
```

At the start `bootstrap.sh` asks for everything it needs, then runs unattended:

| Prompt | When |
| --- | --- |
| `administrator`'s password | only if key login doesn't work yet: installs `SSH_PUBLIC_KEY_FILE`, then once more for `sudo` |
| a new password for `runner` | when the account doesn't exist and the backup has no `runner` autologin password; also used for automatic login |
| a runner registration token | when a runner is neither registered nor in the backup, and `gh` can't create one (needs `admin:org`) |
| whether to reboot at the end | so automatic login starts the `runner` session and the runners come up |

Expect roughly 1–2 hours. Most of it goes to the Xcode upload and expansion,
simulator runtime downloads, and building Squid from source.

To skip the prompts, set `RUNNER_USER_PASSWORD`, `GITHUB_RUNNER_TOKEN` and
pass `--reboot`/`--no-reboot`.

> [!IMPORTANT]
> Xcode's minimum macOS version decides what you can install. Xcode 26.4 and
> later need macOS 26.2+, so on macOS 15 (Sequoia) the newest is 26.3. If
> you want the latest Xcode, pick a macOS 26 image when re-imaging. The xcode
> step checks this before installing anything.

> [!IMPORTANT]
> UTM's `build.yml` looks for Xcode at the Actions variable `HOST_XCODE_PATH`
> (default `/Applications/Xcode_26.0.app`). Xcode is installed as
> `/Applications/Xcode_<version>.app`, so update that variable in the
> `utmapp` organization or repository settings when the version changes.

## Running individual steps

```sh
./bootstrap.sh --list                      # what the steps are
./bootstrap.sh verify                      # read-only health check of a live runner
./bootstrap.sh --xcode-xip X.xip xcode     # install another Xcode
./bootstrap.sh --xcode-xip-on-runner Downloads/X.xip xcode   # ... from an .xip already on the runner
./bootstrap.sh squid verify                # re-deploy squid-patch changes
```

Steps run in this order, and each one is safe to re-run:

| Step | Script | What it does |
| --- | --- | --- |
| `keys` | *(local)* | makes sure key-based SSH works; always runs |
| `sudo` | `remote/00-sudoers.sh` | `/etc/sudoers.d/runner` (passwordless admin, `runner` may run `xcode-select`) |
| `system` | `remote/10-system.sh` | power, Spotlight, software update, screen sharing, sshd hardening |
| `clt` | `remote/15-command-line-tools.sh` | installs the newest Command Line Tools; slow, as it reinstalls every time, so skip it with `--skip clt` when they're current |
| `homebrew` | `remote/20-homebrew.sh` | Homebrew, `files/Brewfile` |
| `squid` | `remote/30-squid.sh` | `squid-patch/deploy.sh --system` |
| `user` | `remote/40-runner-user.sh` | `runner` account, automatic login, dotfiles, git config, pip and gem packages |
| `runners` | `remote/60-actions-runners.sh` | downloads (checksum-verified) and registers the runners; `.env`, `.path`, LaunchAgents |
| `maintenance` | `remote/70-maintenance.sh` | weekly Xcode/SwiftPM/clang cache cleanup |
| `xcode` | `remote/50-xcode.sh` | Xcode from `.xip`, license, first launch, simulator runtimes, Metal toolchain |
| `activate` | `remote/80-activate.sh` | loads the runner LaunchAgents, rebooting into automatic login first if needed |
| `verify` | `remote/90-verify.sh` | checks all of the above |

`bootstrap.sh` copies `lib/`, `remote/`, `files/`, `squid-patch/` and the
resolved configuration to `~/runner-setup` on the runner, then runs the steps
there as `administrator`.

## Configuration and secrets

All settings are in [`config.env`](config.env): account names, runner count
and names, labels, Xcode options, and so on. The machine's address
(`RUNNER_HOST`) is not committed: set it in `config.local.env`. Templates in
`files/` use `@NAME@` placeholders filled in from it. Nothing machine-specific
is hard-coded in the scripts.

**This repository must not contain secrets.** None are committed:

| Secret | Where it comes from | Where it goes |
| --- | --- | --- |
| SSH host keys | backup, else generated by macOS | `/etc/ssh/` |
| `runner` account password | `RUNNER_USER_PASSWORD`, the backup's `kcpassword`, or a prompt | piped over SSH to `sysadminctl`; macOS keeps it for automatic login in `/etc/kcpassword` |
| runner credentials | backup, else `config.sh` with a registration token | `~runner/actions/runner-N/.runner`, `.credentials*` |
| runner registration token | `GITHUB_RUNNER_TOKEN`, `gh api`, or a prompt (only if there is no usable backup) | piped over SSH to `config.sh`; expires after 1 hour |
| Squid CA key | backup, else generated by `deploy.sh` | `/opt/homebrew/etc/squid/` |
| Apple ID | not used: you download Xcode yourself | — |

`.gitignore` excludes `secrets/`, `secrets.*/`, `config.local.env`, `*.xip` and
key files. During a run, the backup is copied to `~/runner-setup/secrets` on
the runner and deleted again when `bootstrap.sh` exits.

## Layout

```
bootstrap.sh            entry point, run on your Mac
backup.sh               pulls the runner's secrets into secrets/ (git-ignored)
config.env              all settings
lib/common.sh           logging, template and runner-file helpers (local and remote)
lib/local.sh            config, SSH and upload for bootstrap.sh / backup.sh
lib/remote.sh           setup shared by the remote steps
remote/backup-export.sh collects the secrets on the runner for backup.sh
remote/NN-*.sh          the steps, run on the runner
files/                  templates and files installed on the runner
tools/latest-xcode.sh   newest Xcode for a macOS version
squid-patch/            submodule: patched Squid formula, config and deploy.sh
docs/                   reference, operations
```

`squid-patch` is maintained separately (a gist) and used here unchanged,
through its own `deploy.sh`. See [docs/operations.md](docs/operations.md#updating-squid-patch).
