#!/usr/bin/env bash
# Deploy automations/*.yaml naar Home Assistant. Verwijdert nooit remote bestanden.
set -euo pipefail

# shellcheck source=./scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

DRY_RUN=0 BACKUP=0 RELOAD=1

usage() {
  cat <<USAGE
Gebruik: ./deploy-automations.sh [--dry-run] [--backup] [--no-reload]

  --dry-run      Toon wat er zou gebeuren, wijzig niets op Home Assistant
  --backup       Maak remote een kopie van te overschrijven bestanden
                 (in <automations>/.backups/<tijdstempel>/)
  --no-reload    Laad de automations na het uploaden niet opnieuw in Home Assistant
  -h, --help     Deze hulp

Herladen gebeurt via de Home Assistant API en vereist HASS_TOKEN in .env.
Zonder token wordt alleen geüpload en krijg je een instructie om handmatig te herladen.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --backup) BACKUP=1 ;;
    --no-reload) RELOAD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Onbekende optie: $1" ;;
  esac
  shift
done

load_env

# 1. Lokale bestanden verzamelen (alleen automations/*.yaml)
shopt -s nullglob
FILES=()
for f in "$REPO_ROOT"/automations/*.yaml; do
  name="$(basename "$f")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Bestandsnaam met onveilige tekens: $name"
  FILES+=("$f")
done
shopt -u nullglob
[[ ${#FILES[@]} -gt 0 ]] || die "Geen automationbestanden om te uploaden in automations/"

# 2. Lokale validatie: geldige YAML, en elk bestand is een lijst (nodig voor !include_dir_merge_list)
info "YAML valideren"
validate_yaml "${FILES[@]}"
python3 -I - "${FILES[@]}" <<'PY' || die "Automationbestanden moeten een lijst van automations bevatten."
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
        print(f"  GEEN LIJST {p}: begin elke automation met '- '", file=sys.stderr); bad += 1; continue
    for i, a in enumerate(data):
        if not isinstance(a, dict):
            print(f"  {p}: item {i + 1} is geen automation", file=sys.stderr); bad += 1; continue
        aid = a.get("id")
        if aid is not None:
            if aid in ids:
                print(f"  DUBBELE id '{aid}' in {p} en {ids[aid]}", file=sys.stderr); bad += 1
            ids[aid] = p
sys.exit(1 if bad else 0)
PY
ok "Structuur geldig"

# 3. Remote controles
info "Verbinding en doelmap controleren"
check_ssh
resolve_config_dir
AUTO_DIR="$CONFIG_DIR/$HASS_AUTOMATION_SUBDIR"
[[ "$AUTO_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Doelpad bevat onveilige tekens: $AUTO_DIR"

if ! rsh "grep -Eq '^[^#]*!include_dir_(merge_)?list[[:space:]]+$HASS_AUTOMATION_SUBDIR/?[[:space:]]*\$' $CONFIG_DIR/configuration.yaml"; then
  warn "configuration.yaml verwijst nog niet naar $HASS_AUTOMATION_SUBDIR/. Voeg toe (zie docs/technisch.md):"
  warn "  automation manual: !include_dir_merge_list $HASS_AUTOMATION_SUBDIR/"
fi

if rsh "test -e $AUTO_DIR && ! test -d $AUTO_DIR"; then
  die "$AUTO_DIR bestaat maar is geen map."
fi
if rsh "test -d $AUTO_DIR"; then
  rsh "test -w $AUTO_DIR" || die "$AUTO_DIR is niet schrijfbaar."
elif [[ $DRY_RUN -eq 1 ]]; then
  info "(dry-run) $AUTO_DIR zou worden aangemaakt"
else
  rsh "mkdir -p $AUTO_DIR" || die "Kon $AUTO_DIR niet aanmaken."
fi

# 4. Verschillen bepalen (sha256 lokaal vs. remote)
CHANGED=()
info "Bestanden in $AUTO_DIR:"
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  local_sum="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  remote_sum="$(rsh "sha256sum $AUTO_DIR/$name 2>/dev/null" | cut -d' ' -f1 || true)"
  if [[ -z "$remote_sum" ]]; then
    printf '  + %s (nieuw)\n' "$name"; CHANGED+=("$f")
  elif [[ "$remote_sum" != "$local_sum" ]]; then
    printf '  ~ %s (gewijzigd)\n' "$name"; CHANGED+=("$f")
  else
    printf '  = %s (ongewijzigd)\n' "$name"
  fi
done

if [[ ${#CHANGED[@]} -eq 0 ]]; then
  ok "Alles is al up-to-date; niets te uploaden."
  exit 0
fi
if [[ $DRY_RUN -eq 1 ]]; then
  info "Dry-run: er is niets gewijzigd. ${#CHANGED[@]} bestand(en) zouden worden geüpload."
  exit 0
fi

# 5. Optionele remote backup
if [[ $BACKUP -eq 1 ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  bdir="$AUTO_DIR/.backups/$ts"
  for f in "${CHANGED[@]}"; do
    name="$(basename "$f")"
    if rsh "test -f $AUTO_DIR/$name"; then
      rsh "mkdir -p $bdir && cp -p $AUTO_DIR/$name $bdir/$name" || die "Backup van $name mislukt."
      printf '  backup: %s/%s\n' "$bdir" "$name"
    fi
  done
fi

# 6. Uploaden: eerst naar tijdelijk bestand, daarna atomair hernoemen
TMP_REMOTE=()
cleanup() {
  local t
  for t in "${TMP_REMOTE[@]+"${TMP_REMOTE[@]}"}"; do rsh "rm -f $t" 2>/dev/null || true; done
}
trap cleanup EXIT

info "Uploaden met scp (tijdelijk bestand + rename)"
for f in "${CHANGED[@]}"; do
  name="$(basename "$f")"
  tmp="$AUTO_DIR/.$name.deploy.$$"
  TMP_REMOTE+=("$tmp")
  scp -q -P "$HASS_PORT" -i "$HASS_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$f" "$SSH_TARGET:$tmp" \
    || die "Upload van $name mislukt."
  rsh "chmod 644 $tmp && mv -f $tmp $AUTO_DIR/$name" || die "Plaatsen van $name mislukt."
  printf '  geüpload: %s\n' "$name"
done
TMP_REMOTE=()
ok "Upload klaar (${#CHANGED[@]} bestand(en))."

# 7. Configuratie controleren en automations herladen via de API
manual_reload() {
  cat <<MSG

Automations herladen:
  Ontwikkelhulpmiddelen > Acties > 'automation.reload' uitvoeren
  (of Instellingen > Systeem > Herstarten bij de eerste registratie in configuration.yaml).
MSG
}

if [[ $RELOAD -eq 0 ]]; then
  manual_reload; exit 0
fi
if [[ -z "$HASS_TOKEN" ]]; then
  warn "HASS_TOKEN ontbreekt in .env; automations worden niet automatisch herladen."
  manual_reload; exit 0
fi

api() { # api <POST|GET> <pad>; token via stdin-config zodat hij niet in de proceslijst staat
  printf 'header = "Authorization: Bearer %s"\n' "$HASS_TOKEN" \
    | curl -sS --max-time 30 -K - -X "$1" -H 'Content-Type: application/json' "$HASS_URL$2"
}

info "Home Assistant-configuratie controleren"
check="$(api POST /api/config/core/check_config)" || die "API niet bereikbaar op $HASS_URL (klopt HASS_URL/HASS_TOKEN?)."
if ! grep -q '"result" *: *"valid"' <<<"$check"; then
  printf '%s\n' "$check" >&2
  die "Home Assistant meldt een ongeldige configuratie; NIET herladen. Bestanden staan wel op de server."
fi
ok "Configuratie geldig"

info "automation.reload uitvoeren"
api POST /api/services/automation/reload -d '{}' >/dev/null || die "Herladen mislukt."
ok "Automations herladen."
