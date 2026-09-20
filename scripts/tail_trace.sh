#!/usr/bin/env bash
#
# Sigue en vivo el trace de razonamiento del agente. Es lo que se proyecta
# durante la demo en lugar de la consola de Bedrock.

set -euo pipefail

cd "$(dirname "$0")/.."

LOG_GROUP="$(terraform output -raw invoke_agent_log_group)"

echo "Siguiendo $LOG_GROUP  (Ctrl-C para salir)"
echo
aws logs tail "$LOG_GROUP" --follow --since 5m --format short
