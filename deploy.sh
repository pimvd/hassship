#!/usr/bin/env bash
# Deploy dashboards/*.yaml to Home Assistant. Never deletes remote files.
set -euo pipefail

# shellcheck source=./scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

DRY_RUN=0 BACKUP=0 PROTECTED=0

usage() {
  cat <<USAGE
Usage: ./deploy.sh [--dry-run] [--backup] [--protected]

  --dry-run      Show what would happen, change nothing on Home Assistant
  --backup       Make a remote copy of files that will be overwritten
                 (in <dashboards>/.backups/<timestamp>/)
  --protected    Also include the protected dashboard (HASS_PROTECTED_DASHBOARD in .env)
                 (skipped by default; confirmation required)
  -h, --help     This help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --backup) BACKUP=1 ;;
    --protected) PROTECTED=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

load_env
PROD_FILE="$HASS_PROTECTED_DASHBOARD"

# 1. Collect local files (only dashboards/*.yaml)
shopt -s nullglob
FILES=()
for f in "$REPO_ROOT"/dashboards/*.yaml; do
  name="$(basename "$f")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "File name with unsafe characters: $name"
  if [[ -n "$PROD_FILE" && "$name" == "$PROD_FILE" && $PROTECTED -eq 0 ]]; then
    warn "$name skipped (protected dashboard; use --protected to include it)"
    continue
  fi
  FILES+=("$f")
done
shopt -u nullglob
[[ ${#FILES[@]} -gt 0 ]] || die "No dashboard files to upload in dashboards/"

if [[ $PROTECTED -eq 1 && -n "$PROD_FILE" && $DRY_RUN -eq 0 ]]; then
  warn "You are about to upload $PROD_FILE to Home Assistant."
  read -r -p "Type YES to continue: " answer
  [[ "$answer" == "YES" ]] || die "Aborted."
fi

# 2. Local validation
info "Validating YAML"
validate_yaml "${FILES[@]}"

# 3. Remote checks
info "Checking connection and target directory"
check_ssh
resolve_config_dir
[[ "$DASH_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Target path contains unsafe characters: $DASH_DIR"

if rsh "test -e $DASH_DIR && ! test -d $DASH_DIR"; then
  die "$DASH_DIR exists but is not a directory."
fi
if rsh "test -d $DASH_DIR"; then
  rsh "test -w $DASH_DIR" || die "$DASH_DIR is not writable."
elif [[ $DRY_RUN -eq 1 ]]; then
  info "(dry-run) $DASH_DIR would be created"
else
  rsh "mkdir -p $DASH_DIR" || die "Could not create $DASH_DIR."
fi

# 4. Determine differences (sha256 local vs. remote)
CHANGED=()
info "Files in $DASH_DIR:"
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  local_sum="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  remote_sum="$(rsh "sha256sum $DASH_DIR/$name 2>/dev/null" | cut -d' ' -f1 || true)"
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
  bdir="$DASH_DIR/.backups/$ts"
  for f in "${CHANGED[@]}"; do
    name="$(basename "$f")"
    if rsh "test -f $DASH_DIR/$name"; then
      rsh "mkdir -p $bdir && cp -p $DASH_DIR/$name $bdir/$name" || die "Backup of $name failed."
      printf '  backup: %s/%s\n' "$bdir" "$name"
    fi
  done
fi

# 6. Upload: first to a temp file, then rename atomically
HAVE_RSYNC=0
if command -v rsync >/dev/null 2>&1 && rsh "command -v rsync >/dev/null 2>&1"; then
  HAVE_RSYNC=1
fi

TMP_REMOTE=()
cleanup() {
  local t
  for t in "${TMP_REMOTE[@]+"${TMP_REMOTE[@]}"}"; do rsh "rm -f $t" 2>/dev/null || true; done
}
trap cleanup EXIT

if [[ $HAVE_RSYNC -eq 1 ]]; then
  info "Uploading with rsync (temp file + rename, no --delete)"
  ssh_cmd="ssh"
  for a in "${SSH_OPTS[@]}"; do ssh_cmd+=" '$a'"; done
  names=()
  for f in "${CHANGED[@]}"; do names+=("$(basename "$f")"); done
  (cd "$REPO_ROOT/dashboards" && rsync -t --checksum --itemize-changes -e "$ssh_cmd" \
      "${names[@]}" "$SSH_TARGET:$DASH_DIR/") || die "rsync failed; nothing was permanently replaced for failed files."
else
  info "Uploading with scp (temp file + rename)"
  for f in "${CHANGED[@]}"; do
    name="$(basename "$f")"
    tmp="$DASH_DIR/.$name.deploy.$$"
    TMP_REMOTE+=("$tmp")
    scp -q -P "$HASS_PORT" -i "$HASS_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$f" "$SSH_TARGET:$tmp" \
      || die "Upload of $name failed."
    rsh "chmod 644 $tmp && mv -f $tmp $DASH_DIR/$name" || die "Placing $name failed."
    printf '  uploaded: %s\n' "$name"
  done
  TMP_REMOTE=()
fi

ok "Deployment done (${#CHANGED[@]} file(s))."
cat <<MSG

Refreshing the dashboard:
  - Change to an existing YAML dashboard: refresh the browser (Cmd+Shift+R)
    or in the app: Settings > Companion app > Debugging > Reset frontend cache.
  - First registration in configuration.yaml: Settings > System > Restart
    (YAML dashboards are not reloaded without a restart).
MSG
