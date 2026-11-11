#!/usr/bin/env bash
# Gedeelde functies voor deploy.sh, pull.sh en check-connection.sh.
# Wordt gesourced; niet direct uitvoeren.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWAARSCHUWING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFOUT:\033[0m %s\n' "$*" >&2; exit 1; }

# Quote een string veilig voor de remote shell.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

load_env() {
  local envfile="$REPO_ROOT/.env"
  [[ -f "$envfile" ]] || die ".env ontbreekt. Voer uit: cp .env.example .env  (en pas aan)"
  set -a
  # shellcheck disable=SC1090
  source "$envfile"
  set +a
  HASS_HOST="${HASS_HOST:-homeassistant.local}"
  HASS_USER="${HASS_USER:-root}"
  HASS_PORT="${HASS_PORT:-22}"
  HASS_SSH_KEY="${HASS_SSH_KEY:-$HOME/.ssh/hass_deploy}"
  HASS_SSH_KEY="${HASS_SSH_KEY/#\~/$HOME}"
  HASS_CONFIG_DIR="${HASS_CONFIG_DIR:-}"
  HASS_DASHBOARD_SUBDIR="${HASS_DASHBOARD_SUBDIR:-dashboards}"
  HASS_PROTECTED_DASHBOARD="${HASS_PROTECTED_DASHBOARD:-}"
  HASS_AUTOMATION_SUBDIR="${HASS_AUTOMATION_SUBDIR:-automations}"
  HASS_TOKEN="${HASS_TOKEN:-}"
  HASS_URL="${HASS_URL:-https://$HASS_HOST}"
  HASS_URL="${HASS_URL%/}"
  [[ "$HASS_AUTOMATION_SUBDIR" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$HASS_AUTOMATION_SUBDIR" != *..* ]] \
    || die "HASS_AUTOMATION_SUBDIR is ongeldig: '$HASS_AUTOMATION_SUBDIR'"
  [[ "$HASS_PORT" =~ ^[0-9]+$ ]] || die "HASS_PORT moet een getal zijn (nu: '$HASS_PORT')"
  [[ -f "$HASS_SSH_KEY" ]] || die "SSH-sleutel niet gevonden: $HASS_SSH_KEY (zie README, stap 'SSH-sleutel genereren')"
  # Alleen veilige tekens in de submap: voorkomt padontsnapping.
  [[ "$HASS_DASHBOARD_SUBDIR" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$HASS_DASHBOARD_SUBDIR" != *..* ]] \
    || die "HASS_DASHBOARD_SUBDIR is ongeldig: '$HASS_DASHBOARD_SUBDIR'"

  # Hostkey-verificatie staat altijd aan (StrictHostKeyChecking=yes).
  SSH_OPTS=(
    -p "$HASS_PORT"
    -i "$HASS_SSH_KEY"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o ConnectTimeout=10
  )
  SSH_TARGET="$HASS_USER@$HASS_HOST"
}

# Voer een commando op de remote uit.
# shellcheck disable=SC2029  # client-side expansie is bedoeld
rsh() { ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

check_ssh() {
  local err
  if ! err="$(rsh true 2>&1)"; then
    printf '%s\n' "$err" >&2
    if grep -qi 'host key verification failed\|no .* host key is known' <<<"$err"; then
      die "Hostkey onbekend of gewijzigd. Controleer de fingerprint en voeg toe aan known_hosts (zie README)."
    elif grep -qi 'permission denied' <<<"$err"; then
      die "SSH-authenticatie geweigerd. Staat de publieke sleutel in de SSH-app van Home Assistant?"
    fi
    die "SSH-verbinding naar $SSH_TARGET:$HASS_PORT mislukt."
  fi
  ok "SSH bereikbaar: $SSH_TARGET:$HASS_PORT"
}

# Zet CONFIG_DIR en DASH_DIR (remote).
resolve_config_dir() {
  local c
  if [[ -n "$HASS_CONFIG_DIR" ]]; then
    rsh "test -f $(shq "$HASS_CONFIG_DIR/configuration.yaml")" \
      || die "Geen configuration.yaml in HASS_CONFIG_DIR=$HASS_CONFIG_DIR"
    CONFIG_DIR="$HASS_CONFIG_DIR"
  else
    CONFIG_DIR=""
    for c in /config /homeassistant; do
      if rsh "test -f $c/configuration.yaml"; then CONFIG_DIR="$c"; break; fi
    done
    [[ -n "$CONFIG_DIR" ]] \
      || die "configuration.yaml niet gevonden in /config of /homeassistant. Zet HASS_CONFIG_DIR in .env."
  fi
  rsh "test -d $(shq "$CONFIG_DIR") && test -w $(shq "$CONFIG_DIR")" \
    || die "Configuratiemap $CONFIG_DIR is niet schrijfbaar voor $HASS_USER (draait de SSH-app met voldoende rechten?)"
  # shellcheck disable=SC2034  # gebruikt door deploy.sh/pull.sh
  DASH_DIR="$CONFIG_DIR/$HASS_DASHBOARD_SUBDIR"
  ok "Configuratiemap: $CONFIG_DIR (schrijfbaar)"
}

# Valideer YAML-syntax lokaal. HA-tags (!include, !secret, ...) worden toegestaan.
validate_yaml() {
  local f
  [[ $# -gt 0 ]] || return 0
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -I - "$@" <<'PY' || die "YAML-validatie mislukt."
import sys, yaml
class L(yaml.SafeLoader): pass
L.add_multi_constructor("!", lambda loader, suffix, node: None)
bad = 0
for p in sys.argv[1:]:
    try:
        with open(p, encoding="utf-8") as fh:
            list(yaml.load_all(fh, Loader=L))
    except Exception as e:
        bad += 1
        print(f"  ONGELDIG {p}: {e}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
  elif command -v yq >/dev/null 2>&1; then
    for f in "$@"; do yq e '.' "$f" >/dev/null || die "Ongeldige YAML: $f"; done
  else
    die "Geen YAML-validator: installeer PyYAML (pip3 install pyyaml) of yq."
  fi
  ok "YAML-syntax geldig ($# bestand(en))"
}
