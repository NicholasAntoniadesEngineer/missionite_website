#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage: scripts/register-release.sh <tag> [notes...]

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
assets to the GitHub Release for <tag>. Registering also raises the minimum
activatable version to <tag> on both platforms: older builds stop activating.
USAGE
  exit 2
}

: "${SUPABASE_URL:?Set SUPABASE_URL (https://<ref>.supabase.co)}"
: "${SUPABASE_SERVICE_ROLE_KEY:?Set SUPABASE_SERVICE_ROLE_KEY (service_role secret)}"

REPO="${GH_RELEASES_REPO:-NicholasAntoniadesEngineer/ECSS_framework}"
DIST_DIR="${ECSS_DIST_DIR:-/Users/nicholasantoniades/Documents/GitHub/ECSS_framework/dist}"

SUPABASE_URL="${SUPABASE_URL%/}"

if [ "$#" -lt 1 ]; then
  echo "Error: expected at least 1 argument (<tag>), got $#." >&2
  usage
fi

TAG="$1"
shift
NOTES="${*:-}"

VERSION="${TAG#[vV]}"

command -v gh >/dev/null 2>&1 || { echo "Error: gh CLI is required (https://cli.github.com)." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required." >&2; exit 1; }
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run once:  gh auth login" >&2
  exit 1
fi

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

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n'
}

echo "Reading assets for ${REPO}@${TAG} ..." >&2
assets="$(gh api "repos/${REPO}/releases/tags/${TAG}" \
  --jq '.assets[] | [.id, .name, .size] | @tsv')" || {
  echo "Error: could not read release ${TAG} on ${REPO}." >&2
  echo "       Is the tag pushed and the release created (build/publish-github-release.sh)?" >&2
  exit 1
}

pick_asset() {
  local suffix="$1" id name size
  while IFS=$'\t' read -r id name size; do
    [ -n "$name" ] || continue
    case "$name" in *"Licence Minter"*) continue ;; esac
    case "$name" in *"$suffix") printf '%s\t%s\t%s\n' "$id" "$name" "$size"; return 0 ;; esac
  done <<<"$assets"
  return 0
}

mac_line="$(pick_asset '.app.zip')"
win_line="$(pick_asset '.exe')"

[ -n "$mac_line" ] || { echo "Error: no macOS .app.zip asset on ${TAG} (excluding Licence Minter)." >&2; exit 1; }
[ -n "$win_line" ] || { echo "Error: no Windows .exe asset on ${TAG} (excluding Licence Minter)." >&2; exit 1; }

IFS=$'\t' read -r MAC_ID MAC_NAME MAC_SIZE <<<"$mac_line"
IFS=$'\t' read -r WIN_ID WIN_NAME WIN_SIZE <<<"$win_line"

case "$MAC_NAME$WIN_NAME" in *"Licence Minter"*) echo "Error: refusing — Licence Minter matched." >&2; exit 1 ;; esac

for pair in "asset_id:$MAC_ID" "file_size:$MAC_SIZE" "asset_id:$WIN_ID" "file_size:$WIN_SIZE"; do
  val="${pair#*:}"
  case "$val" in ''|*[!0-9]*) echo "Error: non-numeric ${pair%%:*} from GitHub: '$val'." >&2; exit 1 ;; esac
done

# GitHub dots-out spaces in asset names, so glob disk by "Missionite <TAG><suffix>" — matching on $MAC_NAME instead silently stores an empty sha256.
sha_for_suffix() {
  # Two local statements, never 'local a=.. b=..$a': under set -u the second RHS is expanded before the first local exists.
  local suffix="$1"
  local f="$DIST_DIR/Missionite ${TAG}${suffix}"
  if [ -f "$f" ]; then
    file_sha256 "$f"
  else
    echo "Warning: no local ${suffix} in $DIST_DIR for ${TAG}; storing empty sha256." >&2
    printf ''
  fi
}
MAC_SHA="$(sha_for_suffix '.app.zip')"
WIN_SHA="$(sha_for_suffix '.exe')"

VERSION_ESC="$(json_escape "$VERSION")"
NOTES_ESC="$(json_escape "$NOTES")"
MAC_NAME_ESC="$(json_escape "$MAC_NAME")"
WIN_NAME_ESC="$(json_escape "$WIN_NAME")"
MAC_SHA_ESC="$(json_escape "$MAC_SHA")"
WIN_SHA_ESC="$(json_escape "$WIN_SHA")"

BODY="$(cat <<JSON
[
  {"version":"${VERSION_ESC}","platform":"mac","asset_id":${MAC_ID},"asset_name":"${MAC_NAME_ESC}","file_size":${MAC_SIZE},"sha256":"${MAC_SHA_ESC}","notes":"${NOTES_ESC}"},
  {"version":"${VERSION_ESC}","platform":"win","asset_id":${WIN_ID},"asset_name":"${WIN_NAME_ESC}","file_size":${WIN_SIZE},"sha256":"${WIN_SHA_ESC}","notes":"${NOTES_ESC}"}
]
JSON
)"

echo "Upserting 2 release rows into the catalog ..." >&2
TMP_INSERT="$(mktemp)"
HTTP_INSERT="$(curl -sS -o "$TMP_INSERT" -w '%{http_code}' -X POST \
  "${SUPABASE_URL}/rest/v1/releases?on_conflict=version,platform" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge-duplicates,return=representation" \
  --data "$BODY")"

if [ "$HTTP_INSERT" -ge 300 ]; then
  echo "Error: release-row upsert failed (HTTP $HTTP_INSERT):" >&2
  cat "$TMP_INSERT" >&2; echo >&2
  rm -f "$TMP_INSERT"
  exit 1
fi
rm -f "$TMP_INSERT"

current_floor() {
  local platform="$1"
  local body
  body="$(curl -sS "${SUPABASE_URL}/rest/v1/app_policy?platform=eq.${platform}&select=min_version" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
    -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}")" || body=''
  local was
  was="$(printf '%s' "$body" | sed -n 's/.*"min_version":"\([^"]*\)".*/\1/p' | head -1)"
  printf '%s' "${was:-(none)}"
}
MAC_FLOOR_WAS="$(current_floor mac)"
WIN_FLOOR_WAS="$(current_floor win)"

POLICY_BODY="$(cat <<JSON
[
  {"platform":"mac","min_version":"${VERSION_ESC}","updated_at":"now"},
  {"platform":"win","min_version":"${VERSION_ESC}","updated_at":"now"}
]
JSON
)"

echo "Raising the activation floor to ${VERSION} (mac + win) ..." >&2
TMP_POLICY="$(mktemp)"
HTTP_POLICY="$(curl -sS -o "$TMP_POLICY" -w '%{http_code}' -X POST \
  "${SUPABASE_URL}/rest/v1/app_policy?on_conflict=platform" \
  -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" \
  -H "Content-Type: application/json" \
  -H "Prefer: resolution=merge-duplicates,return=representation" \
  --data "$POLICY_BODY")"

if [ "$HTTP_POLICY" -ge 300 ]; then
  echo "Error: the floor was NOT raised (HTTP $HTTP_POLICY):" >&2
  cat "$TMP_POLICY" >&2; echo >&2
  rm -f "$TMP_POLICY"
  echo "       The ${VERSION} catalog rows DID land, so downloads work — but the floor is" >&2
  echo "       still mac=${MAC_FLOOR_WAS} win=${WIN_FLOOR_WAS}, so every older build keeps" >&2
  echo "       activating. Set it by hand, BOTH platforms, with" >&2
  echo "       supabase/queries/set-minimum-version.sql" >&2
  exit 1
fi
rm -f "$TMP_POLICY"

echo "" >&2
echo "Done. Registered Missionite ${VERSION} (tag ${TAG}) from ${REPO}:" >&2
echo "  macOS   : asset_id=${MAC_ID}  ${MAC_NAME}  (${MAC_SIZE} bytes)  sha256=${MAC_SHA:-<none>}" >&2
echo "  Windows : asset_id=${WIN_ID}  ${WIN_NAME}  (${WIN_SIZE} bytes)  sha256=${WIN_SHA:-<none>}" >&2
echo "  floor: mac ${MAC_FLOOR_WAS} -> ${VERSION}" >&2
echo "  floor: win ${WIN_FLOOR_WAS} -> ${VERSION}" >&2
echo "  Builds older than ${VERSION} are refused at activation from now on." >&2
