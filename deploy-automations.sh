#!/usr/bin/env bash
# Kept for convenience: deploys only the automations. See deploy-config.sh for all options.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy-config.sh" "$@" automations
