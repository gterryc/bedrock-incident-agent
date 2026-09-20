#!/usr/bin/env bash
#
# Rompe el ambiente en vivo: quita del SG de los targets la regla de ingress
# que permite el healthcheck desde el SG del ALB.
#
# Uso: ./scripts/break_sg.sh [-y]
#   -y  aplica sin pedir confirmacion (util cuando ya estas en el escenario)

set -euo pipefail

cd "$(dirname "$0")/.."

AUTO_APPROVE=""
if [[ "${1:-}" == "-y" ]]; then
  AUTO_APPROVE="-auto-approve"
fi

echo "=============================================================="
echo " ROMPIENDO EL AMBIENTE"
echo " Se elimina la regla de ingress del healthcheck en el SG de la app."
echo " El target group deberia quedar unhealthy en ~20 segundos y la"
echo " alarma disparar en ~1-2 minutos."
echo "=============================================================="
echo

terraform apply -var="allow_healthcheck=false" ${AUTO_APPROVE}

echo
echo "Listo. Segui el trace del agente con:"
echo "  ./scripts/tail_trace.sh"
