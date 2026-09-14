# Operations

Common tasks on a runner that is already set up. Everything assumes you are in
a checkout of this repository with `config.env` matching the machine.

## Health check

```sh
./bootstrap.sh verify
```

Read-only. Checks sudo, sshd, the Squid daemon, proxying through it (bumped
and spliced), the Xcode selection and components, automatic login, the
packages, and every runner's registration, `.env`, LaunchAgent and listener.
Then confirm the runners show as *Idle* on GitHub (organization settings →
Actions → Runners).

## Backing up secrets

```sh
./backup.sh
```

Run it before a re-image, and again after anything changes a secret: the
`runner` password, runners re-registered with `--reconfigure-runners`, a new
Squid CA, or the first run of this setup. On the old machine automatic login was
`administrator`, so its first backup has no usable `runner` password. What's
in the backup and how it is restored is described in the
[README](../README.md#before-a-re-image-back-up-the-secrets).

If a backup must not be used (e.g. you want a fresh CA), run
`./bootstrap.sh --no-restore`, or move `secrets/` aside.

## Installing a new Xcode

```sh
tools/latest-xcode.sh                               # newest one this macOS supports
./bootstrap.sh --xcode-xip ~/Downloads/Xcode_26.3_Apple_silicon.xip xcode verify
```

The old Xcode is kept. Afterwards:

1. Set the Actions variable `HOST_XCODE_PATH` to the new app, in the `utmapp`
   organization or UTM repository settings.
2. Once no branch needs the old one, delete it:
   `ssh administrator@<host> sudo rm -rf /Applications/Xcode_<old>.app`, and
   remove its simulator runtimes with `xcrun simctl runtime delete <id>`.

If the new Xcode needs a newer macOS, the step stops before installing.
Upgrade macOS first (`sudo softwareupdate -l`, then `-i <label> --restart`), or
re-image with a newer macOS.

## Updating squid-patch

`squid-patch` is a git submodule pointing at the gist. It is maintained
separately, but this runner is where it's deployed, so keep them in step:

```sh
cd squid-patch
git pull                        # or commit your own changes and push them
cd ..
git add squid-patch && git commit -m "Update squid-patch"
./bootstrap.sh squid verify
```

`remote/30-squid.sh` rebuilds Squid only when `squid.rb` changed. Otherwise it
refreshes the helper, certificates bundle and services. A changed `squid.conf`
is **not** overwritten on the machine (deploy.sh keeps local edits and saves a
`.bak`). To force it, set `SQUID_DEPLOY_ARGS="--force-config"` in
`config.local.env` for that run.

To check the machine hasn't drifted from the submodule:

```sh
ssh administrator@<host> 'cat /opt/homebrew/etc/squid.conf' | diff squid-patch/squid.conf -
ssh administrator@<host> 'cat /opt/homebrew/etc/squid/github_store_id_helper.py' | diff squid-patch/github_store_id_helper.py -
ssh administrator@<host> 'cat /opt/homebrew/Library/Taps/osy/homebrew-local/Formula/squid.rb' | diff squid-patch/squid.rb -
```

Useful on the machine:

```sh
sudo launchctl kickstart -k system/org.squid-cache.squid   # restart
squid -k parse                                              # check the config
tail -f /opt/homebrew/var/logs/access.log
awk '{print $4}' /opt/homebrew/var/logs/access.log | sort | uniq -c | sort -rn | head
```

## Adding, removing or re-registering runners

- **More runners:** raise `RUNNER_COUNT`, then `./bootstrap.sh runners activate verify`.
- **Fewer runners:** lower `RUNNER_COUNT`. For each runner being removed,
  run as `runner` on the machine:
  `cd ~/actions/runner-N && ./svc.sh uninstall && ./config.sh remove --token <token>`.
  The runners step warns about directories beyond the count.
- **Re-register all** (e.g. after moving to another org or group):
  `./bootstrap.sh --reconfigure-runners runners activate verify`.

A registration token comes from `gh` (with `admin:org`: `gh auth refresh -s admin:org`),
from `GITHUB_RUNNER_TOKEN`, or from *New runner* on the GitHub settings page.

Restart a runner after changing its `.env`. The restart kills the job it's
running, so check the Actions page first:

```sh
ssh administrator@<host> 'sudo launchctl kickstart -k gui/$(id -u runner)/actions.runner.utmapp.macstadium-1'
```

## Changing settings

Edit `config.env` (or `config.local.env`) and re-run the step that uses the
setting. The step for each setting is in [reference.md](reference.md). For
example, screen sharing is `./bootstrap.sh system`, and Python packages
are `./bootstrap.sh user`.

## Troubleshooting

**Runners offline after a reboot.** Check `./bootstrap.sh verify`. If
"`runner` has a GUI session" fails, automatic login didn't happen. The usual
cause is a changed `runner` password, which leaves the stored autologin
password stale. Re-run `./bootstrap.sh user` with the current password
(`RUNNER_USER_PASSWORD=...`). A macOS update can also stop at a login prompt:
look through Screen Sharing.

**Jobs fail with certificate errors.** Some tool isn't using the variables in
`.env`. Point it at `/opt/homebrew/etc/squid/ca-bundle.pem`. If a host
shouldn't be intercepted, add it to the `ssl_bump splice` rules in
`squid-patch/squid.conf`.

**Everything is a cache miss.** See "Checking that it works" in
[squid-patch/README.md](../squid-patch/README.md).

**`bootstrap.sh` says the host key changed.** Expected after a re-image:
`ssh-keygen -R <host>`. If the machine was *not* re-imaged, find out why
before you do that. With a backup, the `system` step restores the old host
keys and fixes `known_hosts` for you.

**A restored runner stays offline.** Its registration was probably removed on
GitHub, which happens after about 14 days offline.
`~runner/Library/Logs/actions.runner.*/stdout.log` will say so. Register it
again with `./bootstrap.sh --reconfigure-runners runners activate verify`,
then run `./backup.sh`.
