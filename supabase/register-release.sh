#!/usr/bin/env bash
# ============================================================================
# Missionite — register a GitHub Release in the Supabase catalog
# (run LOCALLY by the owner, AFTER build/publish-github-release.sh; never in CI/committed)
# ============================================================================
# The demo binaries live as ASSETS on a GitHub Release of the PRIVATE app repo
# (NicholasAntoniadesEngineer/ECSS_framework) — NOT in Supabase Storage. This
# script does NOT upload any binary. It reads the assets already attached to the
# release for <tag>, then writes the two catalog rows (mac + win) into the
# `releases` table via PostgREST so the website can broker downloads.
#
# For each platform it records the GitHub numeric asset_id (what the get-download
# edge function exchanges for a short-lived signed URL), the asset_name, and the
# asset size (both from the GitHub API), plus a sha256 computed from the matching
# local file in the app repo's dist/ if it is still present.
#
# The VENDOR-ONLY "Licence Minter" assets are deliberately never registered.
#
# Requirements: bash, curl, gh (authenticated), and shasum or sha256sum.
#
# Environment (required):
#   SUPABASE_URL               e.g. https://abcdefghijkl.supabase.co
#   SUPABASE_SERVICE_ROLE_KEY  Settings > API > service_role secret (KEEP SECRET)
#
# Environment (optional):
#   GH_RELEASES_REPO   default NicholasAntoniadesEngineer/ECSS_framework
#   ECSS_DIST_DIR      default /Users/nicholasantoniades/Documents/GitHub/ECSS_framework/dist
#
# Usage:
#   export SUPABASE_URL="https://<ref>.supabase.co"
#   export SUPABASE_SERVICE_ROLE_KEY="<service_role secret>"
#   ./supabase/register-release.sh <tag> [notes...]
#
# Example:
#   ./supabase/register-release.sh v5.3 "Demo build: verification matrix + delivery packages."
#
# Idempotent: re-running for the same <tag> first DELETEs the existing mac+win
# rows for that version, then re-inserts — so it safely replaces.
# ============================================================================
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: register-release.sh <tag> [notes...]

  <tag>       The pushed release tag, e.g. v5.3 (a single leading "v" is stripped
              to form the stored version, so v5.3 is registered as version 5.3).
  [notes...]  Optional release-notes line (everything after the tag).

Required env vars:
  SUPABASE_URL               https://<project-ref>.supabase.co
  SUPABASE_SERVICE_ROLE_KEY  service_role secret (keep out of git / the browser)

Optional env vars:
  GH_RELEASES_REPO           default NicholasAntoniadesEngineer/ECSS_framework
  ECSS_DIST_DIR              default /Users/nicholasantoniades/Documents/GitHub/ECSS_framework/dist

Run this AFTER build/publish-github-release.sh (in the app repo) has uploaded the
assets to the GitHub Release for <tag>.
USAGE
  exit 2
}

# ---- validate environment ----
: "${SUPABASE_URL:?Set SUPABASE_URL (https://<ref>.supabase.co)}"
: "${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY (service_role secret)}"

REPO="${GH_RELEASES_REPO:-NicholasAntoniadesEngineer/ECSS_framework}"
DIST_DIR="${ECSS_DIST_DIR:-/Users/nicholasantoniades/Documents/GitHub/ECSS_framework/dist}"

# Trim any trailing slash on the project URL.
SUPABASE_URL="${SUPABASE_URL%/}"

# ---- validate arguments ----
if [ "$#" -lt 1 ]; then
  echo "Error: expected at least 1 argument (<tag>), got $#." >&2
  usage
fi

TAG="$1"
shift
NOTES="${*:-}"

# Stored version = tag minus a single leading v/V (v5.3 -> 5.3).
VERSION="${TAG#[vV]}"

# ---- tool checks ----
command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI is required (https://cli.github.com)." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required." >&2; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run once:  gh auth login" >&2
  exit 1
fi

# ---- portable sha256 (prefer shasum on macOS, fall back to sha256sum) ----
file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    echo "Error: need shasum or sha256sum to compute the digest." >&2
    exit 1
  fi
}

# Minimal JSON string escaper (handles backslash, double-quote; strips CR/LF).
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

# ---- enumerate the release assets (one API call; id<TAB>name<TAB>size per line) ----
echo "Reading assets for ${REPO}@${TAG} ..." >&2
assets="$(gh api "repos/${REPO}/releases/tags/${TAG}" \
  --jq '.assets[] | [.id, .name, .size] | @tsv')" || {
  echo "Error: could not read release ${TAG} on ${REPO}." >&2
  echo "       Is the tag pushed and the release created (build/publish-github-release.sh)?" >&2
  exit 1
}

# Pick the first non-"Licence Minter" asset whose name ends with <suffix>.
pick_asset() {
  local suffix="$1" id name size
  while IFS=$'\t' read -r id name size; do
    [ -n "$name" ] || continue
    case "$name" in *"Licence Minter"*) continue ;; esac
    case "$name" in *"$suffix") printf '%s\t%s\t%s\n' "$id" "$name" "$size"; return 0 ;; esac
  done <<<"$assets"
  return 0
}

mac_line="$(pick_asset '.dmg')"
win_line="$(pick_asset '.exe')"

[ -n "$mac_line" ] || { echo "Error: no macOS .dmg asset on ${TAG} (excluding Licence Minter)." >&2; exit 1; }
[ -n "$win_line" ] || { echo "Error: no Windows .exe asset on ${TAG} (excluding Licence Minter)." >&2; exit 1; }

IFS=$'\t' read -r MAC_ID MAC_NAME MAC_SIZE <<<"$mac_line"
IFS=$'\t' read -r WIN_ID WIN_NAME WIN_SIZE <<<"$win_line"

# Belt-and-suspenders: never register the vendor-only Licence Minter.
case "$MAC_NAME$WIN_NAME" in *"Licence Minter"*) echo "Error: refusing — Licence Minter matched." >&2; exit 1 ;; esac

# The GitHub API returns numeric id/size; validate before injecting into JSON/URLs.
for pair in "asset_id:$MAC_ID" "file_size:$MAC_SIZE" "asset_id:$WIN_ID" "file_size:$WIN_SIZE"; do
  val="${pair#*:}"
  case "$val" in ''|*[!0-9]*) echo "Error: non-numeric ${pair%%:*} from GitHub: '$val'." >&2; exit 1 ;; esac
done

# ---- sha256 from the local dist artifact, if it is still on disk ----
# GitHub replaces spaces in asset names with dots ("Missionite v5.4 ….dmg" uploads as
# "Missionite.v5.4.….dmg"), so the asset name never matches the on-disk file. Instead glob
# the local file the SAME way build/publish-github-release.sh picked it: newest
# "Missionite <TAG> *<suffix>" excluding the Licence Minter.
sha_for_suffix() {
  local suffix="$1" f
  f=$(ls -t "$DIST_DIR"/"Missionite ${TAG} "*"$suffix" 2>/dev/null | grep -v "Licence Minter" | head -1 || true)
  if [ -n "$f" ] && [ -f "$f" ]; then
    file_sha256 "$f"
  else
    echo "Warning: no local ${suffix} in $DIST_DIR for ${TAG}; storing empty sha256." >&2
    printf ''
  fi
}
MAC_SHA="$(sha_for_suffix '.dmg')"
WIN_SHA="$(sha_for_suffix '.exe')"

# ---- escape strings for JSON ----
VERSION_ESC="$(json_escape "$VERSION")"
NOTES_ESC="$(json_escape "$NOTES")"
MAC_NAME_ESC="$(json_escape "$MAC_NAME")"
WIN_NAME_ESC="$(json_escape "$WIN_NAME")"
MAC_SHA_ESC="$(json_escape "$MAC_SHA")"
WIN_SHA_ESC="$(json_escape "$WIN_SHA")"

# ---- 1) DELETE existing rows for this version (idempotent replace of mac+win) ----
echo "Removing any existing ${VERSION} mac/win rows ..." >&2
DEL_HTTP="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
  "${SUPABASE_URL}/rest/v1/releases?version=eq.${VERSION}&platform=in.(mac,win)" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}")"
if [ "$DEL_HTTP" -ge 300 ]; then
  echo "Error: delete of existing rows failed (HTTP $DEL_HTTP)." >&2
  exit 1
fi

# ---- 2) INSERT both rows via PostgREST (bulk insert = one JSON array) ----
BODY="$(cat <<JSON
[
  {"version":"${VERSION_ESC}","platform":"mac","asset_id":${MAC_ID},"asset_name":"${MAC_NAME_ESC}","file_size":${MAC_SIZE},"sha256":"${MAC_SHA_ESC}","notes":"${NOTES_ESC}"},
  {"version":"${VERSION_ESC}","platform":"win","asset_id":${WIN_ID},"asset_name":"${WIN_NAME_ESC}","file_size":${WIN_SIZE},"sha256":"${WIN_SHA_ESC}","notes":"${NOTES_ESC}"}
]
JSON
)"

echo "Inserting 2 release rows into the catalog ..." >&2
TMP_INSERT="$(mktemp)"
HTTP_INSERT="$(curl -sS -o "$TMP_INSERT" -w '%{http_code}' -X POST \
  "${SUPABASE_URL}/rest/v1/releases" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: return=representation" \
  --data "$BODY")"

if [ "$HTTP_INSERT" -ge 300 ]; then
  echo "Error: release-row insert failed (HTTP $HTTP_INSERT):" >&2
  cat "$TMP_INSERT" >&2; echo >&2
  rm -f "$TMP_INSERT"
  exit 1
fi
rm -f "$TMP_INSERT"

echo "" >&2
echo "Done. Registered Missionite ${VERSION} (tag ${TAG}) from ${REPO}:" >&2
echo "  macOS   : asset_id=${MAC_ID}  ${MAC_NAME}  (${MAC_SIZE} bytes)  sha256=${MAC_SHA:-<none>}" >&2
echo "  Windows : asset_id=${WIN_ID}  ${WIN_NAME}  (${WIN_SIZE} bytes)  sha256=${WIN_SHA:-<none>}" >&2
