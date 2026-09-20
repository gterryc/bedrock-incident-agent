#!/usr/bin/env bash
#
# Restaura la regla de ingress del healthcheck y deja el ambiente sano otra vez.
# Sirve para ensayar la demo varias veces sin destruir y recrear todo.
#
# Uso: ./scripts/restore_sg.sh [-y]

set -euo pipefail

cd "$(dirname "$0")/.."

AUTO_APPROVE=""
if [[ "${1:-}" == "-y" ]]; then
  AUTO_APPROVE="-auto-approve"
fi

echo "Restaurando la regla de ingress del healthcheck..."
terraform apply -var="allow_healthcheck=true" ${AUTO_APPROVE}

echo
echo "Listo. Los targets deberian volver a healthy en ~20 segundos."
echo "Verifica con: ./scripts/check_health.sh"
