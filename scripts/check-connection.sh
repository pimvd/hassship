#!/usr/bin/env bash
# Controleert SSH, configuratiemap, tools en lovelace-configuratie op Home Assistant.
set -euo pipefail

# shellcheck source=./lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_env

info "Host $HASS_HOST bereikbaar op poort $HASS_PORT?"
if command -v nc >/dev/null 2>&1; then
  nc -z -w 5 "$HASS_HOST" "$HASS_PORT" >/dev/null 2>&1 \
    || die "Poort $HASS_PORT op $HASS_HOST niet bereikbaar (SSH-app gestart? Juiste poort? Bent u thuis/op VPN?)"
  ok "TCP-verbinding gelukt"
fi

check_ssh
resolve_config_dir

info "Aanwezigheid van configuration.yaml: $CONFIG_DIR/configuration.yaml"
if rsh "grep -q '^lovelace:' $(shq "$CONFIG_DIR/configuration.yaml")"; then
  warn "Er bestaat al een 'lovelace:'-sectie. Voeg alleen 'dashboards:' toe (zie README); maak NIET van de hele sectie 'mode: yaml'."
  rsh "sed -n '/^lovelace:/,/^[^ #]/p' $(shq "$CONFIG_DIR/configuration.yaml")" | sed 's/^/    | /' || true
else
  ok "Geen 'lovelace:'-sectie: het standaarddashboard staat in storage-modus (productie blijft intact)."
fi

if rsh "ls $(shq "$CONFIG_DIR")/.storage/lovelace* >/dev/null 2>&1"; then
  ok "Storage-modus dashboards aanwezig (UI-beheerd, worden niet door deploy.sh geraakt)"
fi

for t in rsync sha256sum; do
  if rsh "command -v $t >/dev/null 2>&1"; then ok "Remote tool aanwezig: $t"; else warn "Remote tool ontbreekt: $t"; fi
done
if rsh "test -d $(shq "$CONFIG_DIR/$HASS_DASHBOARD_SUBDIR")"; then
  ok "Remote dashboardmap bestaat: $CONFIG_DIR/$HASS_DASHBOARD_SUBDIR"
else
  info "Remote dashboardmap bestaat nog niet; deploy.sh maakt die aan."
fi
ok "Alle controles voltooid."
