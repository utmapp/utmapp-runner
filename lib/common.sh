# Helpers shared by bootstrap.sh (on your machine) and remote/*.sh (on the
# runner). Both run under macOS's /bin/bash 3.2: no associative arrays,
# mapfile or ${var,,}.

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;35m### %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

is_true() { [ "${1:-0}" = 1 ] || [ "${1:-}" = true ] || [ "${1:-}" = yes ]; }

# config_names <file...>: names of the variables assigned in the config files
# that exist.
config_names() {
    local f
    for f in "$@"; do
        [ ! -f "$f" ] || sed -nE 's/^[[:space:]]*([A-Z][A-Z0-9_]*)=.*/\1/p' "$f"
    done | sort -u
}

# render <template>: prints the template with every @NAME@ replaced by the
# value of the environment variable NAME. An unset variable is an error, so a
# typo in a template cannot silently produce an empty setting.
render() {
    perl -pe 's/\@([A-Z][A-Z0-9_]*)\@/exists $ENV{$1} ? $ENV{$1} : die "$ARGV: undefined template variable $1\n"/ge' "$1"
}

# runner_json <file> <key>: a top-level string from one of the Actions runner's
# JSON files (.runner, .credentials), which start with a UTF-8 byte order mark
# that plutil rejects.
runner_json() {
    perl -pe 's/^\xEF\xBB\xBF// if $. == 1' "$1" | plutil -extract "$2" raw -o - - 2>/dev/null
}

# runner_backup_matches <backup dir> <expected name>: the directory holds a
# complete runner registration for this runner name and GITHUB_URL.
runner_backup_matches() {
    local dir="$1" f
    for f in .runner .credentials .credentials_rsaparams; do
        [ -f "$dir/$f" ] || return 1
    done
    [ "$(runner_json "$dir/.runner" agentName)" = "$2" ] \
        && [ "$(runner_json "$dir/.runner" gitHubUrl)" = "${GITHUB_URL%/}" ]
}

# /etc/kcpassword, where macOS keeps the automatic login password: the password
# zero-padded to the next multiple of 12 bytes (always at least one zero) and
# XORed with a fixed key. Both functions read stdin and write stdout, so the
# password never appears on a command line.
kcpassword_encode() {
    perl -e '
        local $/; my $p = <STDIN>;
        my @key = (0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F);
        $p .= "\0" x (12 - length($p) % 12);
        binmode STDOUT;
        print join "", map { chr(ord(substr($p, $_, 1)) ^ $key[$_ % @key]) } 0 .. length($p) - 1;'
}
kcpassword_decode() {
    perl -e '
        binmode STDIN; local $/; my $d = <STDIN>;
        my @key = (0x7D, 0x89, 0x52, 0x23, 0xD2, 0xBC, 0xDD, 0xEA, 0xA3, 0xB9, 0x1F);
        for my $i (0 .. length($d) - 1) {
            my $c = ord(substr($d, $i, 1)) ^ $key[$i % @key];
            last if $c == 0;
            print chr($c);
        }'
}
