#!/bin/bash

set -euo pipefail

PACK="${1:-}"

if [[ -z "$PACK" ]]; then
  echo "Usage: ./update-mods.sh <pack-folder>"
  exit 1
fi

if [[ ! -d "$PACK" ]]; then
  echo "ERROR: Pack folder '$PACK' not found."
  exit 1
fi

MODRINTH_API="https://api.modrinth.com/v2"
USER_AGENT="OptiArk-Upgrader/1.0"
LOG_FILE="update-mods-${PACK}-$(date +%Y%m%d-%H%M%S).log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

UPDATED=(); UNCHANGED=(); SKIPPED_GITHUB=(); NOT_FOUND=(); RE_ENABLED=(); STILL_DISABLED=()

log()     { echo -e "$*" | tee -a "$LOG_FILE"; }
info()    { log "${BLUE}[INFO]${NC}  $*"; }
ok()      { log "${GREEN}[OK]${NC}    $*"; }
warn()    { log "${YELLOW}[WARN]${NC}  $*"; }
fail()    { log "${RED}[FAIL]${NC}  $*"; }
section() { log "\n${BOLD}═══ $* ═══${NC}"; }

for tool in curl python3 sed grep; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: '$tool' is required. Install it first."
    exit 1
  fi
done

echo "OptiArk Mod Update Log — $PACK — $(date)" > "$LOG_FILE"

# ── JSON via python3 (no jq needed) ──────────────────────────────────────────
pick_best_version() {
  python3 - "$1" <<'PYEOF'
import sys, json

data = json.loads(sys.argv[1])
if not data:
    sys.exit(1)

priority = {'release': 0, 'beta': 1, 'alpha': 2}
data.sort(key=lambda v: priority.get(v.get('version_type', 'alpha'), 3))
v = data[0]

files = v.get('files', [])
primary = next((f for f in files if f.get('primary')), files[0] if files else None)
if not primary:
    sys.exit(1)

print(json.dumps({
    'version_id':     v.get('id', ''),
    'version_number': v.get('version_number', ''),
    'version_type':   v.get('version_type', ''),
    'filename':       primary.get('filename', ''),
    'url':            primary.get('url', ''),
    'sha512':         primary.get('hashes', {}).get('sha512', ''),
    'sha1':           primary.get('hashes', {}).get('sha1', ''),
}))
PYEOF
}

extract_field() {
  python3 -c "import sys,json; d=json.loads(sys.argv[1]); print(d.get(sys.argv[2],''))" "$1" "$2" 2>/dev/null || echo ""
}

query_modrinth() {
  local MOD_ID="$1" MC_VER="$2" LOADER="$3"

  local RESP
  RESP=$(curl -sf --globoff \
    -H "User-Agent: $USER_AGENT" \
    "${MODRINTH_API}/project/${MOD_ID}/version?game_versions=%5B%22${MC_VER}%22%5D&loaders=%5B%22${LOADER}%22%5D" \
    2>/dev/null || echo "[]")

  if [[ "$RESP" == "[]" || -z "$RESP" ]]; then
    RESP=$(curl -sf --globoff \
      -H "User-Agent: $USER_AGENT" \
      "${MODRINTH_API}/project/${MOD_ID}/version?game_versions=%5B%22${MC_VER}%22%5D" \
      2>/dev/null || echo "[]")
  fi

  echo "$RESP"
}

apply_update() {
  local MOD_FILE="$1" BEST="$2"

  local VERSION_ID VERSION_NUM VERSION_TYPE NEW_FILENAME NEW_URL NEW_SHA512 NEW_SHA1
  VERSION_ID=$(extract_field "$BEST" "version_id")
  VERSION_NUM=$(extract_field "$BEST" "version_number")
  VERSION_TYPE=$(extract_field "$BEST" "version_type")
  NEW_FILENAME=$(extract_field "$BEST" "filename")
  NEW_URL=$(extract_field "$BEST" "url")
  NEW_SHA512=$(extract_field "$BEST" "sha512")
  NEW_SHA1=$(extract_field "$BEST" "sha1")

  local HASH_FORMAT NEW_HASH
  if [[ -n "$NEW_SHA512" ]]; then
    HASH_FORMAT="sha512"; NEW_HASH="$NEW_SHA512"
  else
    HASH_FORMAT="sha1";   NEW_HASH="$NEW_SHA1"
  fi

  sed -i "s|^filename = .*|filename = \"$NEW_FILENAME\"|"     "$MOD_FILE"
  sed -i "s|^url = .*|url = \"$NEW_URL\"|"                     "$MOD_FILE"
  sed -i "s|^hash-format = .*|hash-format = \"$HASH_FORMAT\"|" "$MOD_FILE"
  sed -i "s|^hash = .*|hash = \"$NEW_HASH\"|"                 "$MOD_FILE"

  python3 - "$MOD_FILE" "$VERSION_ID" <<'PYEOF'
import sys, re
path, new_ver = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = re.sub(
    r'(\[update\.modrinth\][\s\S]*?version\s*=\s*")[^"]+(")',
    r'\g<1>' + new_ver + r'\2',
    content
)
with open(path, 'w') as f:
    f.write(content)
PYEOF

  echo "$VERSION_NUM|$VERSION_TYPE"
}

# ── STEP 1: Read pack metadata ───────────────────────────────────────────────
section "READING PACK METADATA"
PACK_TOML="$PACK/pack.toml"

MC_VERSION=$(grep -oP '(?<=minecraft-version = ")[^"]+' "$PACK_TOML" 2>/dev/null \
  || grep -oP '(?<=minecraft = ")[^"]+' "$PACK_TOML" 2>/dev/null \
  || echo "")

LOADER=$(grep -oiP 'fabric|quilt|neoforge|forge' "$PACK_TOML" \
  | head -1 | tr '[:upper:]' '[:lower:]' || echo "fabric")

if [[ -z "$MC_VERSION" ]]; then
  fail "Could not determine Minecraft version from $PACK_TOML"
  exit 1
fi

info "Pack:       $PACK"
info "MC version: $MC_VERSION"
info "Loader:     $LOADER"

# ── STEP 2: Update enabled mods ──────────────────────────────────────────────
section "UPDATING MODS"
MODS_DIR="$PACK/mods"
DISABLED_DIR="$PACK/mods-disabled"
mkdir -p "$DISABLED_DIR"

mapfile -t MOD_FILES < <(find "$MODS_DIR" -name "*.pw.toml" 2>/dev/null | sort)
TOTAL=${#MOD_FILES[@]}
info "Found $TOTAL mod(s) to check."

for MOD_FILE in "${MOD_FILES[@]}"; do
  MOD_NAME=$(grep -oP '(?<=^name = ")[^"]+' "$MOD_FILE" 2>/dev/null || echo "$(basename "$MOD_FILE" .pw.toml)")
  CURRENT_URL=$(grep -oP '(?<=^url = ")[^"]+' "$MOD_FILE" 2>/dev/null | head -1 || echo "")

  if echo "$CURRENT_URL" | grep -qP "github\.com|raw\.githubusercontent\.com"; then
    warn "$MOD_NAME — GitHub source, skipping (update manually)"
    SKIPPED_GITHUB+=("$MOD_NAME")
    continue
  fi

  MOD_ID=$(grep -A5 '\[update\.modrinth\]' "$MOD_FILE" \
    | grep -oP '(?<=mod-id = ")[^"]+' | head -1 || echo "")
  CURRENT_VERSION_ID=$(grep -A5 '\[update\.modrinth\]' "$MOD_FILE" \
    | grep -oP '(?<=^version = ")[^"]+' | head -1 || echo "")

  if [[ -z "$MOD_ID" ]]; then
    warn "$MOD_NAME — No Modrinth ID in toml, skipping"
    continue
  fi

  info "Checking $MOD_NAME ($MOD_ID)..."
  API_RESP=$(query_modrinth "$MOD_ID" "$MC_VERSION" "$LOADER")

  if [[ "$API_RESP" == "[]" || -z "$API_RESP" ]]; then
    warn "$MOD_NAME — No version found for MC $MC_VERSION on $LOADER, leaving as-is"
    NOT_FOUND+=("$MOD_NAME")
    continue
  fi

  BEST=$(pick_best_version "$API_RESP" || echo "")
  if [[ -z "$BEST" ]]; then
    warn "$MOD_NAME — Could not parse API response, leaving as-is"
    NOT_FOUND+=("$MOD_NAME (parse error)")
    continue
  fi

  LATEST_VERSION_ID=$(extract_field "$BEST" "version_id")

  if [[ -n "$CURRENT_VERSION_ID" && "$CURRENT_VERSION_ID" == "$LATEST_VERSION_ID" ]]; then
    ok "$MOD_NAME — already up to date"
    UNCHANGED+=("$MOD_NAME")
    sleep 0.2
    continue
  fi

  RESULT=$(apply_update "$MOD_FILE" "$BEST")
  VERSION_NUM="${RESULT%%|*}"
  VERSION_TYPE="${RESULT##*|}"

  TYPE_LABEL=""
  [[ "$VERSION_TYPE" != "release" ]] && TYPE_LABEL=" ${YELLOW}[$VERSION_TYPE]${NC}"
  ok "$MOD_NAME → $VERSION_NUM$TYPE_LABEL"
  UPDATED+=("$MOD_NAME → $VERSION_NUM")

  sleep 0.2  # Stay well under Modrinth's 300 req/min rate limit
done

# ── STEP 3: Recheck disabled mods ────────────────────────────────────────────
section "RECHECKING DISABLED MODS"

mapfile -t DISABLED_FILES < <(find "$DISABLED_DIR" -name "*.pw.toml" 2>/dev/null | sort)
info "Found ${#DISABLED_FILES[@]} disabled mod(s) to recheck."

for MOD_FILE in "${DISABLED_FILES[@]}"; do
  MOD_NAME=$(grep -oP '(?<=^name = ")[^"]+' "$MOD_FILE" 2>/dev/null || echo "$(basename "$MOD_FILE" .pw.toml)")
  CURRENT_URL=$(grep -oP '(?<=^url = ")[^"]+' "$MOD_FILE" 2>/dev/null | head -1 || echo "")

  if echo "$CURRENT_URL" | grep -qP "github\.com|raw\.githubusercontent\.com"; then
    warn "$MOD_NAME — GitHub source, check manually"
    STILL_DISABLED+=("$MOD_NAME")
    continue
  fi

  MOD_ID=$(grep -A5 '\[update\.modrinth\]' "$MOD_FILE" \
    | grep -oP '(?<=mod-id = ")[^"]+' | head -1 || echo "")

  if [[ -z "$MOD_ID" ]]; then
    warn "$MOD_NAME — No Modrinth ID in toml, skipping"
    STILL_DISABLED+=("$MOD_NAME")
    continue
  fi

  info "Rechecking $MOD_NAME ($MOD_ID) for MC $MC_VERSION..."
  API_RESP=$(query_modrinth "$MOD_ID" "$MC_VERSION" "$LOADER")

  if [[ "$API_RESP" == "[]" || -z "$API_RESP" ]]; then
    warn "$MOD_NAME — Still not available for MC $MC_VERSION on $LOADER"
    STILL_DISABLED+=("$MOD_NAME")
    sleep 0.2
    continue
  fi

  BEST=$(pick_best_version "$API_RESP" || echo "")
  if [[ -z "$BEST" ]]; then
    warn "$MOD_NAME — Could not parse API response"
    STILL_DISABLED+=("$MOD_NAME (parse error)")
    continue
  fi

  RESULT=$(apply_update "$MOD_FILE" "$BEST")
  VERSION_NUM="${RESULT%%|*}"
  VERSION_TYPE="${RESULT##*|}"

  mv "$MOD_FILE" "$MODS_DIR/"

  TYPE_LABEL=""
  [[ "$VERSION_TYPE" != "release" ]] && TYPE_LABEL=" ${YELLOW}[$VERSION_TYPE]${NC}"
  ok "$MOD_NAME → $VERSION_NUM$TYPE_LABEL — re-enabled, moved to mods/"
  RE_ENABLED+=("$MOD_NAME → $VERSION_NUM")

  sleep 0.2
done

# ── STEP 4: Refresh packwiz index ────────────────────────────────────────────
section "REFRESHING INDEX"
if command -v packwiz &>/dev/null; then
  (cd "$PACK" && packwiz refresh) 2>&1 | tee -a "$LOG_FILE"
  ok "packwiz index refreshed"
else
  warn "packwiz not in PATH — run 'packwiz refresh' manually in $PACK/"
fi

# ── STEP 5: Summary ───────────────────────────────────────────────────────────
section "UPDATE SUMMARY"

log ""
log "${GREEN}${BOLD}✔ Updated (${#UPDATED[@]}/${TOTAL}):${NC}"
for m in "${UPDATED[@]}"; do log "  ${GREEN}✔${NC} $m"; done

if [[ ${#RE_ENABLED[@]} -gt 0 ]]; then
  log ""
  log "${GREEN}${BOLD}✔ Re-enabled from mods-disabled/ (${#RE_ENABLED[@]}):${NC}"
  for m in "${RE_ENABLED[@]}"; do log "  ${GREEN}✔${NC} $m"; done
fi

if [[ ${#UNCHANGED[@]} -gt 0 ]]; then
  log ""
  log "${BLUE}${BOLD}• Already up to date (${#UNCHANGED[@]}):${NC}"
  for m in "${UNCHANGED[@]}"; do log "  ${BLUE}•${NC} $m"; done
fi

if [[ ${#SKIPPED_GITHUB[@]} -gt 0 ]]; then
  log ""
  log "${YELLOW}${BOLD}⚠ GitHub mods — update manually (${#SKIPPED_GITHUB[@]}):${NC}"
  for m in "${SKIPPED_GITHUB[@]}"; do log "  ${YELLOW}⚠${NC} $m"; done
fi

if [[ ${#NOT_FOUND[@]} -gt 0 ]]; then
  log ""
  log "${YELLOW}${BOLD}⚠ No version found for MC $MC_VERSION (left untouched) (${#NOT_FOUND[@]}):${NC}"
  for m in "${NOT_FOUND[@]}"; do log "  ${YELLOW}⚠${NC} $m"; done
fi

if [[ ${#STILL_DISABLED[@]} -gt 0 ]]; then
  log ""
  log "${RED}${BOLD}✘ Still disabled — not available for MC $MC_VERSION (${#STILL_DISABLED[@]}):${NC}"
  for m in "${STILL_DISABLED[@]}"; do log "  ${RED}✘${NC} $m"; done
fi

log ""
log "${BOLD}Pack folder:${NC} $PACK"
log "${BOLD}Log saved:${NC}   $LOG_FILE"
