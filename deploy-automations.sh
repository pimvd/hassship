#!/usr/bin/env bash
# Deploy automations/*.yaml to Home Assistant. Never deletes remote files.
set -euo pipefail

# shellcheck source=./scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

DRY_RUN=0 BACKUP=0 RELOAD=1

usage() {
  cat <<USAGE
Usage: ./deploy-automations.sh [--dry-run] [--backup] [--no-reload]

  --dry-run      Show what would happen, change nothing on Home Assistant
  --backup       Make a remote copy of files that will be overwritten
                 (in <automations>/.backups/<timestamp>/)
  --no-reload    Do not reload the automations in Home Assistant after uploading
  -h, --help     This help

Reloading uses the Home Assistant API and requires HASS_TOKEN in .env.
Without a token files are only uploaded and you get instructions to reload manually.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --backup) BACKUP=1 ;;
    --no-reload) RELOAD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

load_env

# 1. Collect local files (only automations/*.yaml)
shopt -s nullglob
FILES=()
for f in "$REPO_ROOT"/automations/*.yaml; do
  name="$(basename "$f")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "File name with unsafe characters: $name"
  FILES+=("$f")
done
shopt -u nullglob
[[ ${#FILES[@]} -gt 0 ]] || die "No automation files to upload in automations/"

# 2. Local validation: valid YAML, and every file is a list (needed for !include_dir_merge_list)
info "Validating YAML"
validate_yaml "${FILES[@]}"
python3 -I - "${FILES[@]}" <<'PY' || die "Automation files must contain a list of automations."
import sys, yaml
class L(yaml.SafeLoader): pass
L.add_multi_constructor("!", lambda loader, suffix, node: None)
ids, bad = {}, 0
for p in sys.argv[1:]:
    with open(p, encoding="utf-8") as fh:
        data = yaml.load(fh, Loader=L)
    if data is None:
        data = []
    if not isinstance(data, list):
        print(f"  NOT A LIST {p}: start every automation with '- '", file=sys.stderr); bad += 1; continue
    for i, a in enumerate(data):
        if not isinstance(a, dict):
            print(f"  {p}: item {i + 1} is not an automation", file=sys.stderr); bad += 1; continue
        aid = a.get("id")
        if aid is not None:
            if aid in ids:
                print(f"  DUPLICATE id '{aid}' in {p} and {ids[aid]}", file=sys.stderr); bad += 1
            ids[aid] = p
sys.exit(1 if bad else 0)
PY
ok "Structure valid"

# 3. Remote checks
info "Checking connection and target directory"
check_ssh
resolve_config_dir
AUTO_DIR="$CONFIG_DIR/$HASS_AUTOMATION_SUBDIR"
[[ "$AUTO_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Target path contains unsafe characters: $AUTO_DIR"

if ! rsh "grep -Eq '^[^#]*!include_dir_(merge_)?list[[:space:]]+$HASS_AUTOMATION_SUBDIR/?[[:space:]]*\$' $CONFIG_DIR/configuration.yaml"; then
  warn "configuration.yaml does not reference $HASS_AUTOMATION_SUBDIR/ yet. Add (see docs/technical.md):"
  warn "  automation manual: !include_dir_merge_list $HASS_AUTOMATION_SUBDIR/"
fi

if rsh "test -e $AUTO_DIR && ! test -d $AUTO_DIR"; then
  die "$AUTO_DIR exists but is not a directory."
fi
if rsh "test -d $AUTO_DIR"; then
  rsh "test -w $AUTO_DIR" || die "$AUTO_DIR is not writable."
elif [[ $DRY_RUN -eq 1 ]]; then
  info "(dry-run) $AUTO_DIR would be created"
else
  rsh "mkdir -p $AUTO_DIR" || die "Could not create $AUTO_DIR."
fi

# 4. Determine differences (sha256 local vs. remote)
CHANGED=()
info "Files in $AUTO_DIR:"
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  local_sum="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  remote_sum="$(rsh "sha256sum $AUTO_DIR/$name 2>/dev/null" | cut -d' ' -f1 || true)"
  if [[ -z "$remote_sum" ]]; then
    printf '  + %s (new)\n' "$name"; CHANGED+=("$f")
  elif [[ "$remote_sum" != "$local_sum" ]]; then
    printf '  ~ %s (changed)\n' "$name"; CHANGED+=("$f")
  else
    printf '  = %s (unchanged)\n' "$name"
  fi
done

if [[ ${#CHANGED[@]} -eq 0 ]]; then
  ok "Everything is already up to date; nothing to upload."
  exit 0
fi
if [[ $DRY_RUN -eq 1 ]]; then
  info "Dry-run: nothing was changed. ${#CHANGED[@]} file(s) would be uploaded."
  exit 0
fi

# 5. Optional remote backup
if [[ $BACKUP -eq 1 ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  bdir="$AUTO_DIR/.backups/$ts"
  for f in "${CHANGED[@]}"; do
    name="$(basename "$f")"
    if rsh "test -f $AUTO_DIR/$name"; then
      rsh "mkdir -p $bdir && cp -p $AUTO_DIR/$name $bdir/$name" || die "Backup of $name failed."
      printf '  backup: %s/%s\n' "$bdir" "$name"
    fi
  done
fi

# 6. Upload: first to a temp file, then rename atomically
TMP_REMOTE=()
cleanup() {
  local t
  for t in "${TMP_REMOTE[@]+"${TMP_REMOTE[@]}"}"; do rsh "rm -f $t" 2>/dev/null || true; done
}
trap cleanup EXIT

info "Uploading with scp (temp file + rename)"
for f in "${CHANGED[@]}"; do
  name="$(basename "$f")"
  tmp="$AUTO_DIR/.$name.deploy.$$"
  TMP_REMOTE+=("$tmp")
  scp -q -P "$HASS_PORT" -i "$HASS_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$f" "$SSH_TARGET:$tmp" \
    || die "Upload of $name failed."
  rsh "chmod 644 $tmp && mv -f $tmp $AUTO_DIR/$name" || die "Placing $name failed."
  printf '  uploaded: %s\n' "$name"
done
TMP_REMOTE=()
ok "Upload done (${#CHANGED[@]} file(s))."

# 7. Check configuration and reload automations via the API
manual_reload() {
  cat <<MSG

Reload automations:
  Developer tools > Actions > run 'automation.reload'
  (or Settings > System > Restart for the first registration in configuration.yaml).
MSG
}

if [[ $RELOAD -eq 0 ]]; then
  manual_reload; exit 0
fi
if [[ -z "$HASS_TOKEN" ]]; then
  warn "HASS_TOKEN is missing in .env; automations are not reloaded automatically."
  manual_reload; exit 0
fi

api() { # api <POST|GET> <path>; token via stdin config so it does not appear in the process list
  printf 'header = "Authorization: Bearer %s"\n' "$HASS_TOKEN" \
    | curl -sS --max-time 30 -K - -X "$1" -H 'Content-Type: application/json' "$HASS_URL$2"
}

info "Checking Home Assistant configuration"
check="$(api POST /api/config/core/check_config)" || die "API not reachable at $HASS_URL (are HASS_URL/HASS_TOKEN correct?)."
if ! grep -q '"result" *: *"valid"' <<<"$check"; then
  printf '%s\n' "$check" >&2
  die "Home Assistant reports an invalid configuration; NOT reloading. The files are on the server, though."
fi
ok "Configuration valid"

info "Running automation.reload"
api POST /api/services/automation/reload -d '{}' >/dev/null || die "Reload failed."
ok "Automations reloaded."
