#!/usr/bin/env bash
# Fetch dashboard files from Home Assistant into dashboards/.
# Never silently overwrites local changes: diff first, then confirmation + backup.
set -euo pipefail

# shellcheck source=./scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

ASSUME_YES=0
REQUESTED=()

usage() {
  cat <<USAGE
Usage: ./pull.sh [--yes] [file.yaml ...]

  Without file names, all *.yaml in the remote dashboard directory are fetched.
  --yes   Skip the confirmation prompt (backup and diff still apply)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "Unknown option: $1" ;;
    *) REQUESTED+=("$1") ;;
  esac
  shift
done

load_env
info "Checking connection and remote configuration"
check_ssh
resolve_config_dir
[[ "$DASH_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Target path contains unsafe characters: $DASH_DIR"

storage_hint() {
  local st
  st="$(rsh "ls $CONFIG_DIR/.storage/lovelace* 2>/dev/null" || true)"
  if [[ -n "$st" ]]; then
    printf 'Found storage-mode dashboards:\n%s\n' "$st" >&2
  fi
  die "No YAML file available for this dashboard: it is in storage mode (managed in the UI).
Open the dashboard > three dots > Edit dashboard > three dots > 'Raw configuration editor'
and copy the contents manually to dashboards/<name>.yaml."
}

NAMES=()
if [[ ${#REQUESTED[@]} -gt 0 ]]; then
  for n in "${REQUESTED[@]}"; do
    n="$(basename "$n")"
    [[ "$n" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || die "Invalid file name: $n"
    rsh "test -f $DASH_DIR/$n" || storage_hint
    NAMES+=("$n")
  done
else
  while IFS= read -r n; do
    [[ -n "$n" && "$n" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] && NAMES+=("$n")
  done < <(rsh "find $DASH_DIR -maxdepth 1 -type f -name '*.yaml' -exec basename {} \;" 2>/dev/null || true)
  [[ ${#NAMES[@]} -gt 0 ]] || storage_hint
fi

TMPDIR_PULL="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PULL"' EXIT
mkdir -p "$REPO_ROOT/dashboards"

TO_WRITE=()
for n in "${NAMES[@]}"; do
  rsh "cat $DASH_DIR/$n" > "$TMPDIR_PULL/$n" || die "Fetching $n failed."
  local_f="$REPO_ROOT/dashboards/$n"
  if [[ ! -f "$local_f" ]]; then
    printf '  + %s (new locally)\n' "$n"; TO_WRITE+=("$n")
  elif cmp -s "$local_f" "$TMPDIR_PULL/$n"; then
    printf '  = %s (identical)\n' "$n"
  else
    printf '  ~ %s (differs) - diff (local -> remote):\n' "$n"
    diff -u "$local_f" "$TMPDIR_PULL/$n" || true
    TO_WRITE+=("$n")
  fi
done

if [[ ${#TO_WRITE[@]} -eq 0 ]]; then
  ok "Nothing to do: local equals remote."
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "Write ${#TO_WRITE[@]} file(s) to dashboards/? [y/N] " answer
  [[ "$answer" =~ ^[yY]$ ]] || die "Aborted; nothing overwritten."
fi

bdir="$REPO_ROOT/.backups/local-$(date +%Y%m%d-%H%M%S)"
for n in "${TO_WRITE[@]}"; do
  if [[ -f "$REPO_ROOT/dashboards/$n" ]]; then
    mkdir -p "$bdir"
    cp -p "$REPO_ROOT/dashboards/$n" "$bdir/$n"
  fi
  cp "$TMPDIR_PULL/$n" "$REPO_ROOT/dashboards/$n"
  printf '  written: dashboards/%s\n' "$n"
done
[[ -d "$bdir" ]] && info "Backup of old local versions: $bdir"
ok "Pull done. Check with git diff."
