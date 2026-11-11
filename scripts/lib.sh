#!/usr/bin/env bash
# Shared functions for deploy.sh, deploy-automations.sh, pull.sh and check-connection.sh.
# Sourced; do not run directly.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Quote a string safely for the remote shell.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

load_env() {
  local envfile="$REPO_ROOT/.env"
  [[ -f "$envfile" ]] || die ".env is missing. Run: cp .env.example .env  (and edit it)"
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
  HASS_SCRIPT_SUBDIR="${HASS_SCRIPT_SUBDIR:-ha-scripts}"
  HASS_SCENE_SUBDIR="${HASS_SCENE_SUBDIR:-ha-scenes}"
  HASS_TOKEN="${HASS_TOKEN:-}"
  HASS_URL="${HASS_URL:-https://$HASS_HOST}"
  HASS_URL="${HASS_URL%/}"
  [[ "$HASS_AUTOMATION_SUBDIR" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$HASS_AUTOMATION_SUBDIR" != *..* ]] \
    || die "HASS_AUTOMATION_SUBDIR is invalid: '$HASS_AUTOMATION_SUBDIR'"
  local sub
  for sub in "$HASS_SCRIPT_SUBDIR" "$HASS_SCENE_SUBDIR"; do
    [[ "$sub" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$sub" != *..* ]] || die "Invalid subdirectory in .env: '$sub'"
  done
  [[ "$HASS_PORT" =~ ^[0-9]+$ ]] || die "HASS_PORT must be a number (now: '$HASS_PORT')"
  [[ -f "$HASS_SSH_KEY" ]] || die "SSH key not found: $HASS_SSH_KEY (see README, 'Create an SSH key')"
  # Only safe characters in the subdirectory: prevents path escapes.
  [[ "$HASS_DASHBOARD_SUBDIR" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "$HASS_DASHBOARD_SUBDIR" != *..* ]] \
    || die "HASS_DASHBOARD_SUBDIR is invalid: '$HASS_DASHBOARD_SUBDIR'"

  # Host key verification is always on (StrictHostKeyChecking=yes).
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

# Run a command on the remote.
# shellcheck disable=SC2029  # client-side expansion is intended
# -n: never read stdin, so rsh is safe inside "while read" loops.
rsh() { ssh -n "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

check_ssh() {
  local err
  if ! err="$(rsh true 2>&1)"; then
    printf '%s\n' "$err" >&2
    if grep -qi 'host key verification failed\|no .* host key is known' <<<"$err"; then
      die "Host key unknown or changed. Verify the fingerprint and add it to known_hosts (see docs/technical.md)."
    elif grep -qi 'permission denied' <<<"$err"; then
      die "SSH authentication refused. Is the public key in the Home Assistant SSH add-on, and is it loaded in your ssh-agent if it has a passphrase?"
    fi
    die "SSH connection to $SSH_TARGET:$HASS_PORT failed."
  fi
  ok "SSH reachable: $SSH_TARGET:$HASS_PORT"
}

# Sets CONFIG_DIR and DASH_DIR (remote).
resolve_config_dir() {
  local c
  if [[ -n "$HASS_CONFIG_DIR" ]]; then
    rsh "test -f $(shq "$HASS_CONFIG_DIR/configuration.yaml")" \
      || die "No configuration.yaml in HASS_CONFIG_DIR=$HASS_CONFIG_DIR"
    CONFIG_DIR="$HASS_CONFIG_DIR"
  else
    CONFIG_DIR=""
    for c in /config /homeassistant; do
      if rsh "test -f $c/configuration.yaml"; then CONFIG_DIR="$c"; break; fi
    done
    [[ -n "$CONFIG_DIR" ]] \
      || die "configuration.yaml not found in /config or /homeassistant. Set HASS_CONFIG_DIR in .env."
  fi
  rsh "test -d $(shq "$CONFIG_DIR") && test -w $(shq "$CONFIG_DIR")" \
    || die "Config directory $CONFIG_DIR is not writable for $HASS_USER (does the SSH add-on have enough rights?)"
  # shellcheck disable=SC2034  # used by deploy.sh/pull.sh
  DASH_DIR="$CONFIG_DIR/$HASS_DASHBOARD_SUBDIR"
  ok "Config directory: $CONFIG_DIR (writable)"
}

# Validate YAML syntax locally. HA tags (!include, !secret, ...) are allowed.
validate_yaml() {
  local f
  [[ $# -gt 0 ]] || return 0
  if python3 -c 'import yaml' 2>/dev/null; then
    python3 -I - "$@" <<'PY' || die "YAML validation failed."
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
        print(f"  INVALID {p}: {e}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
  elif command -v yq >/dev/null 2>&1; then
    for f in "$@"; do yq e '.' "$f" >/dev/null || die "Invalid YAML: $f"; done
  else
    die "No YAML validator: install PyYAML (pip3 install pyyaml) or yq."
  fi
  ok "YAML syntax valid ($# file(s))"
}
