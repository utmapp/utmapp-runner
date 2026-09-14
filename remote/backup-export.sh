#!/bin/bash
#
# Collects the runner's secrets and writes them to stdout as a .tar.gz, for
# backup.sh. Read-only on the machine. Progress goes to stderr.
#
# Layout of the archive (and of SECRETS_DIR):
#   manifest.txt                      when, from where, sha256 of every file
#   ssh/ssh_host_*_key{,.pub}         sshd host keys
#   ssh/authorized_keys               ADMIN_USER's authorized public keys
#   squid/squid-self-signed.{key,crt,pem}, squid-self-signed_dhparam.pem
#   runners/runner-N/.runner, .runner_migrated, .credentials, .credentials_rsaparams
#   autologin/kcpassword, autologin/user

. "$(dirname "$0")/../lib/remote.sh"
exec 3>&1 1>&2

out="$(mktemp -d)"
trap 'sudo rm -rf "$out"' EXIT
mkdir -p "$out/ssh" "$out/squid" "$out/runners" "$out/autologin"

grab() {  # grab <source> <destination in the archive>
    if sudo test -f "$1"; then
        sudo cp "$1" "$out/$2"
        ok "$1"
    fi
}

step "SSH"
# DSA host keys are skipped: OpenSSH no longer supports them.
for key in /etc/ssh/ssh_host_*_key; do
    case "$key" in *_dsa_key) continue ;; esac
    grab "$key" "ssh/$(basename "$key")"
    grab "$key.pub" "ssh/$(basename "$key").pub"
done
grab "$HOME/.ssh/authorized_keys" ssh/authorized_keys

step "Squid CA"
for f in squid-self-signed.key squid-self-signed.crt squid-self-signed.pem squid-self-signed_dhparam.pem; do
    grab "$SQUID_CONF_DIR/$f" "squid/$f"
done

step "Runner registrations"
if sudo test -d "$RUNNERS_ROOT"; then
    for dir in $(sudo find "$RUNNERS_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'runner-*' | sort); do
        sudo test -f "$dir/.runner" || continue
        name="$(basename "$dir")"
        mkdir -p "$out/runners/$name"
        for f in .runner .runner_migrated .credentials .credentials_rsaparams; do
            grab "$dir/$f" "runners/$name/$f"
        done
    done
fi

step "Automatic login"
if sudo test -f /etc/kcpassword; then
    grab /etc/kcpassword autologin/kcpassword
    sudo sysadminctl -autologin status 2>&1 | sed -nE 's/.*Automatic login user: (.*)$/\1/p' > "$out/autologin/user"
    ok "for $(cat "$out/autologin/user")"
fi

sudo chown -R "$(id -u)" "$out"
chmod -R go-rwx "$out"
{
    echo "Backup of $(id -un)@$(ipconfig getifaddr en0 2>/dev/null || hostname)"
    echo "Taken $(date -u '+%Y-%m-%dT%H:%M:%SZ'), macOS $(sw_vers -productVersion)"
    echo
    (cd "$out" && find . -type f ! -name manifest.txt | sort | xargs shasum -a 256)
} > "$out/manifest.txt"

COPYFILE_DISABLE=1 tar -C "$out" -czf - . >&3
