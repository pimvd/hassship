#!/usr/bin/env bash
# Haal dashboardbestanden op van Home Assistant naar dashboards/.
# Overschrijft lokale wijzigingen nooit stilzwijgend: eerst diff, dan bevestiging + backup.
set -euo pipefail

# shellcheck source=./scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

ASSUME_YES=0
REQUESTED=()

usage() {
  cat <<USAGE
Gebruik: ./pull.sh [--yes] [bestand.yaml ...]

  Zonder bestandsnamen worden alle *.yaml in de remote dashboardmap opgehaald.
  --yes   Sla de bevestigingsvraag over (backup en diff blijven gelden)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "Onbekende optie: $1" ;;
    *) REQUESTED+=("$1") ;;
  esac
  shift
done

load_env
info "Verbinding en remote configuratie controleren"
check_ssh
resolve_config_dir
[[ "$DASH_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Doelpad bevat onveilige tekens: $DASH_DIR"

storage_hint() {
  local st
  st="$(rsh "ls $CONFIG_DIR/.storage/lovelace* 2>/dev/null" || true)"
  if [[ -n "$st" ]]; then
    printf 'Gevonden storage-modus dashboards:\n%s\n' "$st" >&2
  fi
  die "Geen YAML-bestand beschikbaar voor dit dashboard: het staat in storage-modus (UI-beheerd).
Open het dashboard > drie puntjes > Dashboard bewerken > drie puntjes > 'Ruwe configuratie-editor'
en kopieer de inhoud handmatig naar dashboards/<naam>.yaml. Productie wordt zo niet overschreven."
}

NAMES=()
if [[ ${#REQUESTED[@]} -gt 0 ]]; then
  for n in "${REQUESTED[@]}"; do
    n="$(basename "$n")"
    [[ "$n" =~ ^[A-Za-z0-9._-]+\.yaml$ ]] || die "Ongeldige bestandsnaam: $n"
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
  rsh "cat $DASH_DIR/$n" > "$TMPDIR_PULL/$n" || die "Ophalen van $n mislukt."
  local_f="$REPO_ROOT/dashboards/$n"
  if [[ ! -f "$local_f" ]]; then
    printf '  + %s (nieuw lokaal)\n' "$n"; TO_WRITE+=("$n")
  elif cmp -s "$local_f" "$TMPDIR_PULL/$n"; then
    printf '  = %s (identiek)\n' "$n"
  else
    printf '  ~ %s (verschilt) - diff (lokaal -> remote):\n' "$n"
    diff -u "$local_f" "$TMPDIR_PULL/$n" || true
    TO_WRITE+=("$n")
  fi
done

if [[ ${#TO_WRITE[@]} -eq 0 ]]; then
  ok "Niets te doen: lokaal is gelijk aan remote."
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "${#TO_WRITE[@]} bestand(en) naar dashboards/ schrijven? [j/N] " answer
  [[ "$answer" =~ ^[jJyY]$ ]] || die "Afgebroken; niets overschreven."
fi

bdir="$REPO_ROOT/.backups/local-$(date +%Y%m%d-%H%M%S)"
for n in "${TO_WRITE[@]}"; do
  if [[ -f "$REPO_ROOT/dashboards/$n" ]]; then
    mkdir -p "$bdir"
    cp -p "$REPO_ROOT/dashboards/$n" "$bdir/$n"
  fi
  cp "$TMPDIR_PULL/$n" "$REPO_ROOT/dashboards/$n"
  printf '  geschreven: dashboards/%s\n' "$n"
done
[[ -d "$bdir" ]] && info "Back-up van oude lokale versies: $bdir"
ok "Pull klaar. Controleer met git diff."
