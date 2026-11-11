#!/usr/bin/env bash
# Checks SSH, the config directory, tools and the lovelace configuration on Home Assistant.
set -euo pipefail

# shellcheck source=./lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

load_env

info "Is host $HASS_HOST reachable on port $HASS_PORT?"
if command -v nc >/dev/null 2>&1; then
  nc -z -w 5 "$HASS_HOST" "$HASS_PORT" >/dev/null 2>&1 \
    || die "Port $HASS_PORT on $HASS_HOST not reachable (SSH add-on started? Right port? At home or on VPN?)"
  ok "TCP connection succeeded"
fi

check_ssh
resolve_config_dir

info "Checking configuration.yaml: $CONFIG_DIR/configuration.yaml"
if rsh "grep -q '^lovelace:' $(shq "$CONFIG_DIR/configuration.yaml")"; then
  warn "A 'lovelace:' section already exists. Only add 'dashboards:' (see docs/technical.md); do NOT make the whole section 'mode: yaml'."
  rsh "sed -n '/^lovelace:/,/^[^ #]/p' $(shq "$CONFIG_DIR/configuration.yaml")" | sed 's/^/    | /' || true
else
  ok "No 'lovelace:' section: the default dashboard is in storage mode (stays intact)."
fi

if rsh "ls $(shq "$CONFIG_DIR")/.storage/lovelace* >/dev/null 2>&1"; then
  ok "Storage-mode dashboards present (managed in the UI, not touched by deploy.sh)"
fi

for t in rsync sha256sum; do
  if rsh "command -v $t >/dev/null 2>&1"; then ok "Remote tool present: $t"; else warn "Remote tool missing: $t"; fi
done
if rsh "test -d $(shq "$CONFIG_DIR/$HASS_DASHBOARD_SUBDIR")"; then
  ok "Remote dashboard directory exists: $CONFIG_DIR/$HASS_DASHBOARD_SUBDIR"
else
  info "Remote dashboard directory does not exist yet; deploy.sh creates it."
fi
ok "All checks completed."
