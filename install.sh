#!/usr/bin/env bash
# One-command installer for RST QRadar AI Copilot.
#
#   curl -fsSL https://github.com/reallysec/RST-Qradar-AI-Copilot/releases/latest/download/install.sh | sudo bash
#
# Options: --version <x.y.z> (default: latest)   --dir <path> (default below)
#          --download-only   verify and save the archive in the current directory, deploy nothing
#                            (carry it to an air-gapped host and run deploy.sh there)
#
# Every edition is the same archive: without a license it runs as the Community Edition;
# importing a license in Settings -> License unlocks Professional or Enterprise in place.
# Downloads the delivery archive and its .sha256 from GitHub Releases, verifies it, unpacks
# it into one fixed directory and runs deploy.sh there. Re-running it (a newer version) keeps
# .env and state/machine-id in that directory, so data and the host fingerprint are kept.
set -euo pipefail

PRODUCT="RST QRadar AI Copilot"
STEM="RST-Qradar-AI-Copilot"                     # archive: <STEM>-<version>.tar.gz
GH_REPO="reallysec/RST-Qradar-AI-Copilot"
# Releases root: <base>/latest redirects to the newest tag, files are <base>/download/v<version>/<file>.
# ponytail: env override exists only so scripts/test_install.sh can point it at a local file:// tree.
RELEASES="${RST_RELEASES_URL:-https://github.com/$GH_REPO/releases}"
DIR="/opt/rst-qradar-ai-copilot"

VERSION=""; DOWNLOAD_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --download-only) DOWNLOAD_ONLY=1; shift ;;
    --version) VERSION="${2#v}"; shift 2 ;;
    --dir)     DIR="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" 2>/dev/null || true; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── preflight ────────────────────────────────────────────────────────────────
for c in curl tar sha256sum; do command -v "$c" >/dev/null || fail "missing command: $c"; done
if [ "$DOWNLOAD_ONLY" = 0 ]; then
  [ "$(uname -s)" = Linux ] || fail "Linux only."
  [ "$(id -u)" = 0 ] || fail "run as root: pipe to 'sudo bash'."
  command -v docker >/dev/null || fail "Docker Engine 24+ is required. Install it first, e.g.: curl -fsSL https://get.docker.com | sh"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required (the docker compose plugin)."
  [ -r /dev/tty ] || fail "deploy.sh asks questions; run this from an interactive terminal."
fi

CURL=(curl -fL --retry 3 --connect-timeout 15)

# Latest version from the /releases/latest redirect (no API call, no rate limit).
latest_version() {
  local u; u="$("${CURL[@]}" -sS -o /dev/null -w '%{url_effective}' "$RELEASES/latest")" || return 1
  u="${u##*/}"
  case "$u" in v[0-9]*) printf '%s' "${u#v}" ;; *) return 1 ;; esac
}

# Download + verify into the current directory; nothing is left behind on failure.
fetch_bundle() {
  [ -n "$VERSION" ] || VERSION="$(latest_version)" || fail "cannot resolve the latest release from $RELEASES (check the network, or pass --version)."
  ARCHIVE="$STEM-$VERSION.tar.gz"
  local base="$RELEASES/download/v$VERSION"
  say "== $PRODUCT $VERSION: downloading from $base"
  if "${CURL[@]}" -o "$ARCHIVE.sha256" "$base/$ARCHIVE.sha256" \
     && "${CURL[@]}" -o "$ARCHIVE" "$base/$ARCHIVE" \
     && sha256sum -c "$ARCHIVE.sha256"; then
    return 0
  fi
  rm -f "$ARCHIVE" "$ARCHIVE.sha256"
  fail "could not download and verify $ARCHIVE. Check the version and the network."
}

if [ "$DOWNLOAD_ONLY" = 1 ]; then
  fetch_bundle
  say "== saved $PWD/$ARCHIVE; on the target host: tar xzf $ARCHIVE && cd $STEM-$VERSION && ./deploy.sh"
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
fetch_bundle
say "== $PRODUCT $VERSION -> $DIR"

# ── unpack into the fixed directory ──────────────────────────────────────────
# The archive carries no .env and no state/, so an existing install keeps both. Old image
# tars are removed first so deploy.sh loads only this version's images.
mkdir -p "$DIR"
rm -f "$DIR"/"$STEM"-images-*.tar
tar xzf "$ARCHIVE" -C "$DIR" --strip-components=1
say "== unpacked; starting deploy.sh"
cd "$DIR"
exec bash ./deploy.sh </dev/tty   # bash: bundles up to 1.1.1 ship deploy.sh without +x
