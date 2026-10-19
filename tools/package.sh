#!/usr/bin/env bash
# Build dist/<name>_<version>.zip from the tracked files under cybersyn/.
# The release workflow and local builds both run this script, so they cannot drift.
#
#   tools/package.sh [--allow-dirty] [--out DIR]
#
# PACKAGE_OUT_DIR=DIR is the same as --out DIR.
# PACKAGE_ALLOW_DEV_INTERFACE=1 skips the dev-interface guard. It exists for test
# builds only (CI dry runs, local checks); a zip built with it must never be released.
set -euo pipefail

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mod="$repo/cybersyn"
out="${PACKAGE_OUT_DIR:-$repo/dist}"
allow_dirty=0

while [ $# -gt 0 ]; do
	case "$1" in
	--allow-dirty) allow_dirty=1 ;;
	--out) out="$2"; shift ;;
	-h | --help) sed -n '2,9p' "$0"; exit 0 ;;
	*) echo "package.sh: unknown argument $1" >&2; exit 2 ;;
	esac
	shift
done

fail() { echo "package.sh: REFUSED: $*" >&2; exit 1; }

read -r name version < <(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["name"], d["version"])' "$mod/info.json")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "info.json version '$version' is not a.b.c"

if [ "$allow_dirty" -eq 0 ] && [ -n "$(git -C "$repo" status --porcelain --untracked-files=no -- cybersyn)" ]; then
	git -C "$repo" status --short --untracked-files=no -- cybersyn >&2
	fail "uncommitted changes in cybersyn/ (commit them, or pass --allow-dirty for a local test build)"
fi

python3 -I "$repo/tools/changelog.py" check --file "$mod/changelog.txt" --version "$version" --top >/dev/null \
	|| fail "changelog.txt is invalid or its first block is not $version (see errors above)"

dev_default=$(python3 -I - "$mod/settings.lua" <<'EOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'name\s*=\s*"cybersyn-manager-dev-interface".*?default_value\s*=\s*(\w+)', src, re.S)
print(m.group(1) if m else "missing")
EOF
)
if [ "$dev_default" != "false" ]; then
	if [ "${PACKAGE_ALLOW_DEV_INTERFACE:-}" = "1" ]; then
		echo "package.sh: WARNING: cybersyn-manager-dev-interface defaults to '$dev_default'; PACKAGE_ALLOW_DEV_INTERFACE=1 set, test build only, do not release this zip" >&2
	else
		fail "settings.lua: startup setting cybersyn-manager-dev-interface has default_value = $dev_default. Release builds need false, or every player gets the test remote interface. See RELEASING.md step 1."
	fi
fi

mkdir -p "$out"
zip_path="$(cd "$out" && pwd)/${name}_${version}.zip"
rm -f "$zip_path"

# Tracked files only, read from the working tree (identical to HEAD once the guard above passed).
python3 -I - "$repo" "$zip_path" "${name}_${version}" <<'EOF'
import os, subprocess, sys, time, zipfile
repo, zip_path, top = sys.argv[1:4]
stamp = int(subprocess.check_output(["git", "-C", repo, "log", "-1", "--format=%ct"]).strip())
date_time = time.gmtime(stamp)[:6]
listing = subprocess.check_output(["git", "-C", repo, "ls-files", "-z", "--", "cybersyn"])
paths = [p for p in listing.decode("utf-8").split("\0") if p]

def shipped(rel):
    parts = rel.split("/")
    return not (any(p.startswith(".") for p in parts) or rel == "CLAUDE.md" or rel.endswith(".zip"))

entries = []
for p in paths:
    rel = p[len("cybersyn/"):]
    full = os.path.join(repo, p)
    if shipped(rel) and os.path.isfile(full) and not os.path.islink(full):
        entries.append((rel, full))
entries.append(("LICENSE", os.path.join(repo, "LICENSE")))
entries.sort()

dirs = set()
for rel, _ in entries:
    parts = rel.split("/")[:-1]
    for i in range(1, len(parts) + 1):
        dirs.add("/".join(parts[:i]) + "/")

with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    for d in [""] + sorted(dirs):
        info = zipfile.ZipInfo(f"{top}/{d}", date_time)
        info.external_attr = 0o40755 << 16
        z.writestr(info, b"")
    for rel, full in entries:
        info = zipfile.ZipInfo(f"{top}/{rel}", date_time)
        info.external_attr = 0o100644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(full, "rb") as f:
            z.writestr(info, f.read())
EOF

python3 -I - "$zip_path" "${name}_${version}" <<'EOF' || { rm -f "$zip_path"; fail "zip failed its content check"; }
import sys, zipfile
zip_path, top = sys.argv[1:3]
names = zipfile.ZipFile(zip_path).namelist()
bad = []
if {n.split("/")[0] for n in names} != {top}:
    bad.append(f"expected one top folder {top}/")
for required in ("info.json", "changelog.txt", "control.lua", "LICENSE"):
    if f"{top}/{required}" not in names:
        bad.append(f"missing {required}")
for n in names:
    parts = n.rstrip("/").split("/")[1:]
    if any(p == "CLAUDE.md" or p == "tests" or p.startswith(".") or p.endswith(".zip") for p in parts):
        bad.append(f"must not ship {n}")
for b in bad:
    print(f"package.sh: {b}", file=sys.stderr)
sys.exit(1 if bad else 0)
EOF

echo "$zip_path"
