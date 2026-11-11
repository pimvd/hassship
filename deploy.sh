#!/usr/bin/env bash
# Deploy dashboards/*.yaml naar Home Assistant. Verwijdert nooit remote bestanden.
set -euo pipefail

# shellcheck source=./scripts/lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/lib.sh"

DRY_RUN=0 BACKUP=0 PROTECTED=0

usage() {
  cat <<USAGE
Gebruik: ./deploy.sh [--dry-run] [--backup] [--protected]

  --dry-run      Toon wat er zou gebeuren, wijzig niets op Home Assistant
  --backup       Maak remote een kopie van te overschrijven bestanden
                 (in <dashboards>/.backups/<tijdstempel>/)
  --protected    Neem ook het beschermde dashboard (HASS_PROTECTED_DASHBOARD in .env) mee
                 (standaard overgeslagen; bevestiging vereist)
  -h, --help     Deze hulp
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --backup) BACKUP=1 ;;
    --protected) PROTECTED=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Onbekende optie: $1" ;;
  esac
  shift
done

load_env
PROD_FILE="$HASS_PROTECTED_DASHBOARD"

# 1. Lokale bestanden verzamelen (alleen dashboards/*.yaml)
shopt -s nullglob
FILES=()
for f in "$REPO_ROOT"/dashboards/*.yaml; do
  name="$(basename "$f")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Bestandsnaam met onveilige tekens: $name"
  if [[ -n "$PROD_FILE" && "$name" == "$PROD_FILE" && $PROTECTED -eq 0 ]]; then
    warn "$name overgeslagen (beschermd dashboard; gebruik --protected om mee te nemen)"
    continue
  fi
  FILES+=("$f")
done
shopt -u nullglob
[[ ${#FILES[@]} -gt 0 ]] || die "Geen dashboardbestanden om te uploaden in dashboards/"

if [[ $PROTECTED -eq 1 && -n "$PROD_FILE" && $DRY_RUN -eq 0 ]]; then
  warn "Je gaat $PROD_FILE naar Home Assistant uploaden."
  read -r -p "Typ JA om door te gaan: " answer
  [[ "$answer" == "JA" ]] || die "Afgebroken."
fi

# 2. Lokale validatie
info "YAML valideren"
validate_yaml "${FILES[@]}"

# 3. Remote controles
info "Verbinding en doelmap controleren"
check_ssh
resolve_config_dir
[[ "$DASH_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Doelpad bevat onveilige tekens: $DASH_DIR"

if rsh "test -e $DASH_DIR && ! test -d $DASH_DIR"; then
  die "$DASH_DIR bestaat maar is geen map."
fi
if rsh "test -d $DASH_DIR"; then
  rsh "test -w $DASH_DIR" || die "$DASH_DIR is niet schrijfbaar."
elif [[ $DRY_RUN -eq 1 ]]; then
  info "(dry-run) $DASH_DIR zou worden aangemaakt"
else
  rsh "mkdir -p $DASH_DIR" || die "Kon $DASH_DIR niet aanmaken."
fi

# 4. Verschillen bepalen (sha256 lokaal vs. remote)
CHANGED=()
info "Bestanden in $DASH_DIR:"
for f in "${FILES[@]}"; do
  name="$(basename "$f")"
  local_sum="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  remote_sum="$(rsh "sha256sum $DASH_DIR/$name 2>/dev/null" | cut -d' ' -f1 || true)"
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
  bdir="$DASH_DIR/.backups/$ts"
  for f in "${CHANGED[@]}"; do
    name="$(basename "$f")"
    if rsh "test -f $DASH_DIR/$name"; then
      rsh "mkdir -p $bdir && cp -p $DASH_DIR/$name $bdir/$name" || die "Backup van $name mislukt."
      printf '  backup: %s/%s\n' "$bdir" "$name"
    fi
  done
fi

# 6. Uploaden: eerst naar tijdelijk bestand, daarna atomair hernoemen
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
  info "Uploaden met rsync (tijdelijk bestand + rename, geen --delete)"
  ssh_cmd="ssh"
  for a in "${SSH_OPTS[@]}"; do ssh_cmd+=" '$a'"; done
  names=()
  for f in "${CHANGED[@]}"; do names+=("$(basename "$f")"); done
  (cd "$REPO_ROOT/dashboards" && rsync -t --checksum --itemize-changes -e "$ssh_cmd" \
      "${names[@]}" "$SSH_TARGET:$DASH_DIR/") || die "rsync mislukt; er is niets definitief vervangen voor mislukte bestanden."
else
  info "Uploaden met scp (tijdelijk bestand + rename)"
  for f in "${CHANGED[@]}"; do
    name="$(basename "$f")"
    tmp="$DASH_DIR/.$name.deploy.$$"
    TMP_REMOTE+=("$tmp")
    scp -q -P "$HASS_PORT" -i "$HASS_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$f" "$SSH_TARGET:$tmp" \
      || die "Upload van $name mislukt."
    rsh "chmod 644 $tmp && mv -f $tmp $DASH_DIR/$name" || die "Plaatsen van $name mislukt."
    printf '  geüpload: %s\n' "$name"
  done
  TMP_REMOTE=()
fi

ok "Deployment klaar (${#CHANGED[@]} bestand(en))."
cat <<MSG

Dashboard vernieuwen:
  - Wijziging aan een bestaand YAML-dashboard: ververs de browser (Cmd+Shift+R)
    of in de app: Instellingen > Companion-app > Gebruikersinterface > Frontend-cache wissen.
  - Eerste registratie in configuration.yaml: Instellingen > Systeem > Herstarten
    (YAML-dashboards worden niet herladen zonder herstart).
MSG
