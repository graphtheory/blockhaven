#!/bin/sh
# Publishes a version of the game: the Windows installer from CI and a Mac
# app built here, both of the commit at the tip of main, as a GitHub
# release — and the manifest every installed game checks at launch, plus
# the version and what is new on https://www.john-z.com/games/.
#
#   Tools/release.sh "Fixed the game closing on Windows" "Wings flap"
#
# Each argument is one line of "what's new"; none is fine. Run it from a
# clean main that is pushed and whose Windows build is green (it waits for
# one still running). It
#
#   1. downloads that run's Blockhaven-Setup.exe and builds the Mac dmg,
#   2. creates the GitHub release v<version> with both attached (which
#      also tags the commit),
#   3. writes games/blockhaven/version.json and the page text in the
#      website repo, through a worktree off origin/master (that repo's own
#      working tree holds unrelated work and is never touched), and pushes,
#      which deploys. Installed games pick the new version up on their
#      next launch.
set -eu
cd "$(dirname "$0")/.."

SITE_REPO="${SITE_REPO:-$HOME/projects/personal-website}"
die() { echo "release: $*" >&2; exit 1; }

[ -z "$(git status --porcelain)" ] || die "the tree has uncommitted changes; commit them first"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "release from main"
git fetch -q origin
SHA="$(git rev-parse HEAD)"
[ "$SHA" = "$(git rev-parse origin/main)" ] || die "HEAD is not origin/main; push (or pull) first"
VERSION="$(cat VERSION).$(git rev-list --count HEAD)"
gh release view "v$VERSION" >/dev/null 2>&1 && die "v$VERSION is already released"
echo "Releasing Blockhaven $VERSION ($SHA)"

# The Windows build of exactly this commit.
RUN="$(gh run list --workflow windows.yml --branch main --limit 20 --json databaseId,headSha \
    --jq "map(select(.headSha == \"$SHA\"))[0].databaseId // empty")"
[ -n "$RUN" ] || die "no Windows build of $SHA yet; wait for the push to start one"
gh run watch "$RUN" --exit-status >/dev/null || die "Windows build $RUN failed"
rm -rf dist/release
gh run download "$RUN" -n Blockhaven-Setup -D dist/release
[ -f dist/release/Blockhaven-Setup.exe ] || die "run $RUN has no Blockhaven-Setup.exe"

Tools/mac/make-app.sh
cp dist/mac/Blockhaven-Mac.dmg dist/release/

# The release: the binaries, on GitHub.
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
NOTES="$(printf '%s\n' "$@" | sed '/^$/d; s/^/- /')"
gh release create "v$VERSION" --target "$SHA" --title "Blockhaven $VERSION" \
    --notes "${NOTES:-Blockhaven $VERSION}" \
    dist/release/Blockhaven-Setup.exe dist/release/Blockhaven-Mac.dmg
DOWNLOADS="https://github.com/$REPO/releases/download/v$VERSION"

# The site, from a throwaway worktree: the manifest and the page, no binaries.
git -C "$SITE_REPO" fetch -q origin
SITE="$(mktemp -d)/site"
git -C "$SITE_REPO" worktree add -q --detach "$SITE" origin/master
trap 'git -C "$SITE_REPO" worktree remove --force "$SITE"' EXIT
GAME="$SITE/public/games/blockhaven"
mkdir -p "$GAME"

python3 -I - "$SITE/public/games/index.html" "$GAME/version.json" "$VERSION" "$DOWNLOADS" \
    dist/release/Blockhaven-Setup.exe dist/release/Blockhaven-Mac.dmg "$@" <<'PY'
import datetime, html, json, os, re, sys

page, manifest, version, downloads, exe, dmg, *notes = sys.argv[1:]
today = datetime.date.today()
mb = lambda path: f"{os.path.getsize(path) / 1e6:.1f}".rstrip("0").rstrip(".") + " MB"

# What every installed game reads at launch (Engine/Updater.swift).
with open(manifest, "w") as f:
    json.dump({
        "version": version,
        "date": today.isoformat(),
        "notes": notes,
        "windows": {"url": f"{downloads}/Blockhaven-Setup.exe", "size": os.path.getsize(exe)},
        "mac": {"url": f"{downloads}/Blockhaven-Mac.dmg", "size": os.path.getsize(dmg)},
    }, f, indent=2)
    f.write("\n")

text = open(page, encoding="utf-8").read()
meta = (f"Version {version} · {today.day} {today:%B %Y} · updates itself when it starts<br>\n"
        f"            Windows: {mb(exe)} · Windows 10 or 11, 64-bit<br>\n"
        f"            Mac: {mb(dmg)} · macOS 15 Sequoia or later · Apple silicon and Intel")
text, count = re.subn(r"(<!-- release:meta -->).*?(<!-- /release:meta -->)",
                      lambda m: f"{m[1]}\n            {meta}\n            {m[2]}", text, flags=re.S)
assert count == 1, "the page has no release:meta markers"
entry = f"<li><strong>{version}</strong> · {today.isoformat()}"
if notes:
    entry += "<ul>" + "".join(f"<li>{html.escape(n)}</li>" for n in notes) + "</ul>"
entry += "</li>"
text, count = re.subn(r"(<!-- release:history -->)", lambda m: f"{m[1]}\n              {entry}", text)
assert count == 1, "the page has no release:history marker"
open(page, "w", encoding="utf-8").write(text)
PY

git -C "$SITE" add public/games
git -C "$SITE" commit -q -m "Blockhaven $VERSION"
git -C "$SITE" push -q origin HEAD:master
git fetch -q --tags origin
echo "Published $VERSION: $DOWNLOADS — the site deploys in a few minutes, and installed games update on their next launch."
