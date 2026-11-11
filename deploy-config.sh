#!/usr/bin/env bash
# Deploy automations, scripts and scenes (YAML files in this repo) to Home Assistant.
#   automations/*.yaml  -> <config>/automations/   (each file: a list)
#   ha-scripts/*.yaml   -> <config>/ha-scripts/    (each file: a map of scripts)
#   ha-scenes/*.yaml    -> <config>/ha-scenes/     (each file: a list of scenes)
# Never deletes remote files, unless you pass --prune (with confirmation).
set -euo pipefail

# shellcheck source=./scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

DRY_RUN=0 BACKUP=0 RELOAD=1 PRUNE=0
TYPES=()

usage() {
  cat <<USAGE
Usage: ./deploy-config.sh [--dry-run] [--backup] [--no-reload] [--prune] [type ...]

  type           automations, scripts and/or scenes (default: all that have files)
  --dry-run      Show what would happen, change nothing on Home Assistant
  --backup       Make a remote copy of files that will be overwritten or pruned
                 (in <dir>/.backups/<timestamp>/)
  --no-reload    Do not reload in Home Assistant after uploading
  --prune        Also delete remote *.yaml files that no longer exist locally
                 (asks for confirmation; use --backup to keep a copy)
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
    --prune) PRUNE=1 ;;
    automations|scripts|scenes) TYPES+=("$1") ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

load_env
EXPLICIT=1
if [[ ${#TYPES[@]} -eq 0 ]]; then TYPES=(automations scripts scenes); EXPLICIT=0; fi

# Per type: local dir, remote subdir, structure (list|map), reload service, include line.
type_local()   { case "$1" in automations) echo automations;; scripts) echo ha-scripts;; scenes) echo ha-scenes;; esac; }
type_remote()  { case "$1" in automations) echo "$HASS_AUTOMATION_SUBDIR";; scripts) echo "$HASS_SCRIPT_SUBDIR";; scenes) echo "$HASS_SCENE_SUBDIR";; esac; }
type_kind()    { case "$1" in scripts) echo map;; *) echo list;; esac; }
type_service() { case "$1" in automations) echo automation;; scripts) echo script;; scenes) echo scene;; esac; }
type_include() {
  case "$1" in
    automations) echo "automation manual: !include_dir_merge_list $HASS_AUTOMATION_SUBDIR/" ;;
    scripts)     echo "script manual: !include_dir_merge_named $HASS_SCRIPT_SUBDIR/" ;;
    scenes)      echo "scene manual: !include_dir_merge_list $HASS_SCENE_SUBDIR/" ;;
  esac
}

# --- 1. Collect + validate everything locally first (nothing is touched remotely yet) ---
# bash 3.2 (macOS) has no associative arrays: per-type lists live in files in $WORK.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ACTIVE=()
shopt -s nullglob
for t in "${TYPES[@]}"; do
  : > "$WORK/$t.files"
  for f in "$REPO_ROOT/$(type_local "$t")"/*.yaml; do
    name="$(basename "$f")"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "File name with unsafe characters: $name"
    printf '%s\n' "$f" >> "$WORK/$t.files"
  done
  if [[ ! -s "$WORK/$t.files" ]]; then
    [[ $EXPLICIT -eq 1 ]] && die "No $t files to upload in $(type_local "$t")/"
    continue
  fi
  ACTIVE+=("$t")
done
shopt -u nullglob
[[ ${#ACTIVE[@]} -gt 0 ]] || die "Nothing to deploy: no YAML files in automations/, ha-scripts/ or ha-scenes/"

info "Validating YAML"
for t in "${ACTIVE[@]}"; do
  fl=(); while IFS= read -r l; do fl+=("$l"); done < "$WORK/$t.files"
  validate_yaml "${fl[@]}"
  python3 -I - "$(type_kind "$t")" "$t" "${fl[@]}" <<'PY' || die "Invalid $t files."
import sys, yaml
class L(yaml.SafeLoader): pass
L.add_multi_constructor("!", lambda loader, suffix, node: None)
kind, label, files = sys.argv[1], sys.argv[2], sys.argv[3:]
seen, bad = {}, 0
for p in files:
    with open(p, encoding="utf-8") as fh:
        data = yaml.load(fh, Loader=L)
    if data is None:
        data = [] if kind == "list" else {}
    if kind == "list":
        if not isinstance(data, list):
            print(f"  NOT A LIST {p}: start every item with '- '", file=sys.stderr); bad += 1; continue
        for i, a in enumerate(data):
            if not isinstance(a, dict):
                print(f"  {p}: item {i + 1} is not a mapping", file=sys.stderr); bad += 1; continue
            key = a.get("id") if label != "scenes" else (a.get("id") or a.get("name"))
            if key is not None:
                if key in seen:
                    print(f"  DUPLICATE '{key}' in {p} and {seen[key]}", file=sys.stderr); bad += 1
                seen[key] = p
    else:
        if not isinstance(data, dict):
            print(f"  NOT A MAP {p}: expected 'script_key: {{...}}'", file=sys.stderr); bad += 1; continue
        for key in data:
            if key in seen:
                print(f"  DUPLICATE script '{key}' in {p} and {seen[key]}", file=sys.stderr); bad += 1
            seen[key] = p
sys.exit(1 if bad else 0)
PY
done
ok "Structure valid"

# --- 2. Remote checks ---
info "Checking connection and target directories"
check_ssh
resolve_config_dir
for t in "${ACTIVE[@]}"; do
  d="$CONFIG_DIR/$(type_remote "$t")"
  [[ "$d" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Target path contains unsafe characters: $d"
  if ! rsh "grep -Eq '^[^#]*!include_dir_(merge_)?(list|named)[[:space:]]+$(type_remote "$t")/?[[:space:]]*\$' $CONFIG_DIR/configuration.yaml"; then
    warn "configuration.yaml does not reference $(type_remote "$t")/ yet. Add (see docs/technical.md):"
    warn "  $(type_include "$t")"
  fi
  if rsh "test -e $d && ! test -d $d"; then die "$d exists but is not a directory."; fi
  if rsh "test -d $d"; then
    rsh "test -w $d" || die "$d is not writable."
  elif [[ $DRY_RUN -eq 1 ]]; then
    info "(dry-run) $d would be created"
  else
    rsh "mkdir -p $d" || die "Could not create $d."
  fi
done

# --- 3. Determine differences (sha256 local vs. remote) ---
ANY_CHANGE=0
for t in "${ACTIVE[@]}"; do
  d="$CONFIG_DIR/$(type_remote "$t")"
  : > "$WORK/$t.changed"; : > "$WORK/$t.prune"
  info "Files in $d:"
  while IFS= read -r f; do
    name="$(basename "$f")"
    local_sum="$(shasum -a 256 "$f" | cut -d' ' -f1)"
    remote_sum="$(rsh "sha256sum $d/$name 2>/dev/null" | cut -d' ' -f1 || true)"
    if [[ -z "$remote_sum" ]]; then
      printf '  + %s (new)\n' "$name"; printf '%s\n' "$f" >> "$WORK/$t.changed"
    elif [[ "$remote_sum" != "$local_sum" ]]; then
      printf '  ~ %s (changed)\n' "$name"; printf '%s\n' "$f" >> "$WORK/$t.changed"
    else
      printf '  = %s (unchanged)\n' "$name"
    fi
  done < "$WORK/$t.files"
  if [[ $PRUNE -eq 1 ]] && rsh "test -d $d"; then
    while IFS= read -r rn; do
      [[ "$rn" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || continue
      [[ -f "$REPO_ROOT/$(type_local "$t")/$rn" ]] && continue
      printf '  - %s (only on Home Assistant; would be deleted)\n' "$rn"; printf '%s\n' "$rn" >> "$WORK/$t.prune"
    done < <(rsh "find $d -maxdepth 1 -type f -name '*.yaml' -exec basename {} \;" 2>/dev/null || true)
  fi
  if [[ -s "$WORK/$t.changed" || -s "$WORK/$t.prune" ]]; then ANY_CHANGE=1; fi
done

if [[ $ANY_CHANGE -eq 0 ]]; then
  ok "Everything is already up to date; nothing to do."
  exit 0
fi
if [[ $DRY_RUN -eq 1 ]]; then
  info "Dry-run: nothing was changed."
  exit 0
fi

PRUNE_ANY=0
for t in "${ACTIVE[@]}"; do [[ -s "$WORK/$t.prune" ]] && PRUNE_ANY=1; done
if [[ $PRUNE_ANY -eq 1 ]]; then
  warn "--prune will delete the remote files marked with '-' above."
  read -r -p "Type YES to continue: " answer
  [[ "$answer" == "YES" ]] || die "Aborted."
fi

# --- 4. Backup, upload (temp file + atomic rename), prune ---
TMP_REMOTE=()
cleanup() {
  local x
  for x in "${TMP_REMOTE[@]+"${TMP_REMOTE[@]}"}"; do rsh "rm -f $x" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

ts="$(date +%Y%m%d-%H%M%S)"
RELOAD_SERVICES=()
for t in "${ACTIVE[@]}"; do
  d="$CONFIG_DIR/$(type_remote "$t")"
  [[ -s "$WORK/$t.changed" || -s "$WORK/$t.prune" ]] || continue
  bdir="$d/.backups/$ts"
  if [[ -s "$WORK/$t.changed" ]]; then
    if [[ $BACKUP -eq 1 ]]; then
      while IFS= read -r f; do
        name="$(basename "$f")"
        if rsh "test -f $d/$name"; then
          rsh "mkdir -p $bdir && cp -p $d/$name $bdir/$name" || die "Backup of $name failed."
          printf '  backup: %s/%s\n' "$bdir" "$name"
        fi
      done < "$WORK/$t.changed"
    fi
    info "Uploading $t with scp (temp file + rename)"
    while IFS= read -r f; do
      name="$(basename "$f")"
      tmp="$d/.$name.deploy.$$"
      TMP_REMOTE+=("$tmp")
      scp -q -P "$HASS_PORT" -i "$HASS_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
          -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$f" "$SSH_TARGET:$tmp" </dev/null \
        || die "Upload of $name failed."
      rsh "chmod 644 $tmp && mv -f $tmp $d/$name" || die "Placing $name failed."
      printf '  uploaded: %s\n' "$name"
    done < "$WORK/$t.changed"
    TMP_REMOTE=()
  fi
  if [[ -s "$WORK/$t.prune" ]]; then
    while IFS= read -r name; do
      if [[ $BACKUP -eq 1 ]]; then
        rsh "mkdir -p $bdir && cp -p $d/$name $bdir/$name" || die "Backup of $name failed."
      fi
      rsh "rm -f $d/$name" || die "Deleting $name failed."
      printf '  deleted: %s\n' "$name"
    done < "$WORK/$t.prune"
  fi
  RELOAD_SERVICES+=("$(type_service "$t")")
done
ok "Upload done."

# --- 5. Check configuration and reload via the API ---
manual_reload() {
  local s
  printf '\nReload in Home Assistant (Developer tools > Actions):\n'
  for s in "${RELOAD_SERVICES[@]}"; do printf '  %s.reload\n' "$s"; done
  printf '  (or Settings > System > Restart for the first registration in configuration.yaml).\n'
}
if [[ $RELOAD -eq 0 ]]; then manual_reload; exit 0; fi
if [[ -z "$HASS_TOKEN" ]]; then
  warn "HASS_TOKEN is missing in .env; nothing is reloaded automatically."
  manual_reload; exit 0
fi

api() { # api <POST|GET> <path> [curl args]; token via stdin config so it does not appear in the process list
  local m="$1" p="$2"; shift 2
  printf 'header = "Authorization: Bearer %s"\n' "$HASS_TOKEN" \
    | curl -sS --max-time 30 -K - -X "$m" -H 'Content-Type: application/json' "$@" "$HASS_URL$p"
}

info "Checking Home Assistant configuration"
check="$(api POST /api/config/core/check_config)" || die "API not reachable at $HASS_URL (are HASS_URL/HASS_TOKEN correct?)."
if ! grep -q '"result" *: *"valid"' <<<"$check"; then
  printf '%s\n' "$check" >&2
  die "Home Assistant reports an invalid configuration; NOT reloading. The files are on the server, though."
fi
ok "Configuration valid"

for s in "${RELOAD_SERVICES[@]}"; do
  info "Running $s.reload"
  api POST "/api/services/$s/reload" -d '{}' >/dev/null || die "Reload of $s failed."
  ok "$s reloaded."
done
