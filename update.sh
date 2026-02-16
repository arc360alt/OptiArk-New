#!/bin/bash

set -euo pipefail

PACK="${1:-}"
NEW_VERSION="${2:-}"

if [[ -z "$PACK" || -z "$NEW_VERSION" ]]; then
  echo "Usage: ./upgrade-pack.sh <pack-folder> <new-mc-version>"
  exit 1
fi

if [[ ! -d "$PACK" ]]; then
  echo "ERROR: Pack folder '$PACK' not found."
  exit 1
fi

NEW_DIR="${PACK}-${NEW_VERSION}"
MODRINTH_API="https://api.modrinth.com/v2"
USER_AGENT="OptiArk-Upgrader/1.0"
LOG_FILE="upgrade-${PACK}-${NEW_VERSION}.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

UPDATED=(); SKIPPED_GITHUB=(); FAILED=()

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

# ── Modrinth query ────────────────────────────────────────────────────────────
# THE FIX: use --globoff so curl doesn't treat [ ] as globs,
# and percent-encode the brackets: [ = %5B  ] = %5D
query_modrinth() {
  local MOD_ID="$1" MC_VER="$2" LOADER="$3"

  # With loader filter
  local RESP
  RESP=$(curl -sf --globoff \
    -H "User-Agent: $USER_AGENT" \
    "${MODRINTH_API}/project/${MOD_ID}/version?game_versions=%5B%22${MC_VER}%22%5D&loaders=%5B%22${LOADER}%22%5D" \
    2>/dev/null || echo "[]")

  # Fallback: without loader filter (some mods use "minecraft" as loader type)
  if [[ "$RESP" == "[]" || -z "$RESP" ]]; then
    RESP=$(curl -sf --globoff \
      -H "User-Agent: $USER_AGENT" \
      "${MODRINTH_API}/project/${MOD_ID}/version?game_versions=%5B%22${MC_VER}%22%5D" \
      2>/dev/null || echo "[]")
  fi

  echo "$RESP"
}

# ── STEP 1: Validate version exists on Modrinth ───────────────────────────────
section "VALIDATING VERSION"
info "Checking '$NEW_VERSION' against Modrinth's version list..."

VERSION_LIST=$(curl -sf --globoff \
  -H "User-Agent: $USER_AGENT" \
  "https://modrinth.com/api/tags/game-versions" 2>/dev/null || echo "[]")

CHECK=$(python3 - "$VERSION_LIST" "$NEW_VERSION" <<'PYEOF'
import sys, json, re
data = json.loads(sys.argv[1])
target = sys.argv[2]

# Accept both old (1.x.x) and new (YY.drop.patch) release versions
all_releases = [v['version'] for v in data if v.get('version_type') == 'release']

if target in all_releases:
    print("yes")
else:
    # Also check snapshots in case user passed e.g. "26.1-snapshot-7"
    all_versions = [v['version'] for v in data]
    if target in all_versions:
        print("yes")
    else:
        print("no")
        # Guess which era the user is targeting and show nearby versions
        def is_new_format(v):
            return bool(re.match(r'^\d{2}\.\d+', v))

        if is_new_format(target):
            nearby = [v['version'] for v in data if re.match(r'^\d{2}\.\d+', v['version'])]
        else:
            # Extract major version prefix e.g. "1.21" from "1.21.4"
            prefix = '.'.join(target.split('.')[:2])
            nearby = [v['version'] for v in data if v['version'].startswith(prefix)]
            if not nearby:
                nearby = [v['version'] for v in data if v.get('version_type') == 'release'][:10]

        print(f"Valid versions matching your input era:")
        print("  " + "  ".join(nearby[:15]))
PYEOF
)

if echo "$CHECK" | grep -q "^no"; then
  fail "'$NEW_VERSION' is NOT a valid Modrinth release version."
  echo "$CHECK" | tail -n +2
  echo ""
  echo "Re-run with a correct version from the list above."
  exit 1
fi
ok "'$NEW_VERSION' confirmed as valid Modrinth version."

# ── STEP 2: Copy pack ─────────────────────────────────────────────────────────
section "SETUP"
echo "OptiArk Upgrade Log — $PACK → $NEW_VERSION — $(date)" > "$LOG_FILE"

if [[ -d "$NEW_DIR" ]]; then
  warn "Folder '$NEW_DIR' already exists. Overwrite? [y/N]"
  read -r CONFIRM
  [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Aborted."; exit 0; }
  rm -rf "$NEW_DIR"
fi

info "Copying $PACK → $NEW_DIR (configs preserved)..."
cp -r "$PACK" "$NEW_DIR"

# ── STEP 3: Read + update pack.toml ──────────────────────────────────────────
section "READING PACK METADATA"
PACK_TOML="$NEW_DIR/pack.toml"

OLD_VERSION=$(grep -oP '(?<=minecraft-version = ")[^"]+' "$PACK_TOML" 2>/dev/null \
  || grep -oP '(?<=minecraft = ")[^"]+' "$PACK_TOML" 2>/dev/null \
  || echo "")

LOADER=$(grep -oiP 'fabric|quilt|neoforge|forge' "$PACK_TOML" \
  | head -1 | tr '[:upper:]' '[:lower:]' || echo "fabric")

info "Pack:        $PACK"
info "Old version: $OLD_VERSION"
info "New version: $NEW_VERSION"
info "Loader:      $LOADER"

[[ -n "$OLD_VERSION" ]] && sed -i "s/$OLD_VERSION/$NEW_VERSION/g" "$PACK_TOML"
ok "pack.toml updated → $NEW_VERSION"

# ── STEP 4: Update mods ───────────────────────────────────────────────────────
section "SCANNING MODS"
MODS_DIR="$NEW_DIR/mods"
DISABLED_DIR="$NEW_DIR/mods-disabled"
mkdir -p "$DISABLED_DIR"

mapfile -t MOD_FILES < <(find "$MODS_DIR" -name "*.pw.toml" 2>/dev/null | sort)
TOTAL=${#MOD_FILES[@]}
info "Found $TOTAL mod(s) to process."

section "UPDATING MODS"

for MOD_FILE in "${MOD_FILES[@]}"; do
  MOD_NAME=$(grep -oP '(?<=^name = ")[^"]+' "$MOD_FILE" 2>/dev/null || echo "$(basename "$MOD_FILE" .pw.toml)")
  CURRENT_URL=$(grep -oP '(?<=^url = ")[^"]+' "$MOD_FILE" 2>/dev/null | head -1 || echo "")

  # Skip GitHub-sourced mods
  if echo "$CURRENT_URL" | grep -qP "github\.com|raw\.githubusercontent\.com"; then
    warn "$MOD_NAME — GitHub source, skipping (update manually)"
    SKIPPED_GITHUB+=("$MOD_NAME")
    continue
  fi

  # Get Modrinth mod ID
  MOD_ID=$(grep -A5 '\[update\.modrinth\]' "$MOD_FILE" \
    | grep -oP '(?<=mod-id = ")[^"]+' | head -1 || echo "")

  if [[ -z "$MOD_ID" ]]; then
    warn "$MOD_NAME — No Modrinth ID in toml, skipping"
    continue
  fi

  info "Checking $MOD_NAME ($MOD_ID)..."

  API_RESP=$(query_modrinth "$MOD_ID" "$NEW_VERSION" "$LOADER")

  if [[ "$API_RESP" == "[]" || -z "$API_RESP" ]]; then
    fail "$MOD_NAME — Not available for MC $NEW_VERSION on $LOADER"
    mv "$MOD_FILE" "$DISABLED_DIR/"
    warn "  → moved to mods-disabled/"
    FAILED+=("$MOD_NAME")
    continue
  fi

  BEST=$(pick_best_version "$API_RESP" || echo "")
  if [[ -z "$BEST" ]]; then
    fail "$MOD_NAME — Could not parse API response"
    FAILED+=("$MOD_NAME (parse error)")
    continue
  fi

  VERSION_ID=$(extract_field "$BEST" "version_id")
  VERSION_NUM=$(extract_field "$BEST" "version_number")
  VERSION_TYPE=$(extract_field "$BEST" "version_type")
  NEW_FILENAME=$(extract_field "$BEST" "filename")
  NEW_URL=$(extract_field "$BEST" "url")
  NEW_SHA512=$(extract_field "$BEST" "sha512")
  NEW_SHA1=$(extract_field "$BEST" "sha1")

  if [[ -n "$NEW_SHA512" ]]; then
    HASH_FORMAT="sha512"; NEW_HASH="$NEW_SHA512"
  else
    HASH_FORMAT="sha1";   NEW_HASH="$NEW_SHA1"
  fi

  # Rewrite toml fields
  sed -i "s|^filename = .*|filename = \"$NEW_FILENAME\"|"   "$MOD_FILE"
  sed -i "s|^url = .*|url = \"$NEW_URL\"|"                   "$MOD_FILE"
  sed -i "s|^hash-format = .*|hash-format = \"$HASH_FORMAT\"|" "$MOD_FILE"
  sed -i "s|^hash = .*|hash = \"$NEW_HASH\"|"               "$MOD_FILE"

  # Update version ID inside [update.modrinth] block only
  python3 - "$MOD_FILE" "$VERSION_ID" <<'PYEOF'
import sys, re
path, new_ver = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
# Replace version = "..." that appears after [update.modrinth]
content = re.sub(
    r'(\[update\.modrinth\][\s\S]*?version\s*=\s*")[^"]+(")',
    r'\g<1>' + new_ver + r'\2',
    content
)
with open(path, 'w') as f:
    f.write(content)
PYEOF

  TYPE_LABEL=""
  [[ "$VERSION_TYPE" != "release" ]] && TYPE_LABEL=" ${YELLOW}[$VERSION_TYPE]${NC}"
  ok "$MOD_NAME → $VERSION_NUM$TYPE_LABEL"
  UPDATED+=("$MOD_NAME → $VERSION_NUM")

  sleep 0.2  # Stay well under Modrinth's 300 req/min rate limit
done

# ── STEP 5: Update Fabric loader version ──────────────────────────────────────
section "UPDATING LOADER VERSION"
info "Fetching latest $LOADER loader for MC $NEW_VERSION..."

if [[ "$LOADER" == "fabric" ]]; then
  LOADER_RESP=$(curl -sf --globoff \
    -H "User-Agent: $USER_AGENT" \
    "https://meta.fabricmc.net/v2/versions/loader/$NEW_VERSION" \
    2>/dev/null || echo "[]")

  NEW_LOADER=$(python3 -c "
import sys, json
data = json.loads(sys.argv[1])
print(data[0]['loader']['version'] if data else '')
" "$LOADER_RESP" 2>/dev/null || echo "")

  if [[ -n "$NEW_LOADER" ]]; then
    sed -i "s/^fabric = .*/fabric = \"$NEW_LOADER\"/" "$PACK_TOML"
    ok "Fabric loader → $NEW_LOADER"
  else
    warn "Could not fetch Fabric loader version, leaving as-is"
  fi
fi

# ── STEP 6: Refresh packwiz index ────────────────────────────────────────────
section "REFRESHING INDEX"
if command -v packwiz &>/dev/null; then
  cd "$NEW_DIR"
  packwiz refresh 2>&1 | tee -a "../$LOG_FILE"
  cd ..
  ok "packwiz index refreshed"
else
  warn "packwiz not in PATH — run 'packwiz refresh' manually in $NEW_DIR/"
fi

# ── STEP 7: Summary ───────────────────────────────────────────────────────────
section "UPGRADE SUMMARY"

log ""
log "${GREEN}${BOLD}✔ Updated (${#UPDATED[@]}/${TOTAL}):${NC}"
for m in "${UPDATED[@]}"; do log "  ${GREEN}✔${NC} $m"; done

if [[ ${#SKIPPED_GITHUB[@]} -gt 0 ]]; then
  log ""
  log "${YELLOW}${BOLD}⚠ GitHub mods — update manually (${#SKIPPED_GITHUB[@]}):${NC}"
  for m in "${SKIPPED_GITHUB[@]}"; do log "  ${YELLOW}⚠${NC} $m"; done
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  log ""
  log "${RED}${BOLD}✘ Not available for MC $NEW_VERSION — disabled (${#FAILED[@]}):${NC}"
  for m in "${FAILED[@]}"; do log "  ${RED}✘${NC} $m"; done
  log ""
  log "  Re-enable when updated:"
  log "  ${BLUE}mv $NEW_DIR/mods-disabled/<mod>.pw.toml $NEW_DIR/mods/${NC}"
fi

log ""
log "${BOLD}Pack folder:${NC} $NEW_DIR"
log "${BOLD}Log saved:${NC}   $LOG_FILE"
log ""
log "Next: cd $NEW_DIR && packwiz modrinth export"