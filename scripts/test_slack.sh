#!/usr/bin/env bash
#
# Prueba el envio a Slack SIN disparar el flujo completo ni mandar emails.
# Invoca directamente la Lambda notify_slack con un evento SNS sintetico.
#
# Uso: ./scripts/test_slack.sh

set -uo pipefail
cd "$(dirname "$0")/.."

FN="$(terraform output -raw invoke_agent_function_name 2>/dev/null | sed 's/invoke-agent/notify-slack/')"
FN="${FN:-bedrock-incident-agent-notify-slack}"

CONFIGURADO="$(aws lambda get-function-configuration --function-name "$FN" \
  --query 'Environment.Variables.SLACK_WEBHOOK_URL' --output text 2>/dev/null)"

if [[ -z "$CONFIGURADO" || "$CONFIGURADO" == "None" ]]; then
  echo "⚠️  SLACK_WEBHOOK_URL esta vacio en la Lambda $FN."
  echo "    Completa slack_webhook_url en terraform.tfvars y corre 'terraform apply'."
  echo "    (La Lambda no falla: loguea el mensaje y termina bien.)"
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/event.json" <<'JSON'
{
  "Records": [{
    "EventSource": "aws:sns",
    "Sns": {
      "Subject": "[Prueba] bedrock-incident-agent",
      "Message": "DIAGNOSTICO AUTOMATICO DE INCIDENTE\n========================================\n\nAlarma      : prueba-de-configuracion\nMetrica     : UnHealthyHostCount (umbral: > 0)\nEstado flujo: ok\n\n----------------------------------------\nANALISIS DEL AGENTE\n----------------------------------------\n\n## Resumen\nEsto es un mensaje de prueba para verificar la integracion con Slack.\nSi lo ves en tu canal, el webhook esta bien configurado.\n\n## Causa raiz\nNinguna: es una prueba."
    }
  }]
}
JSON

echo "Invocando $FN ..."
RESP="$(aws lambda invoke --function-name "$FN" \
  --cli-binary-format raw-in-base64-out \
  --payload "file://$TMP/event.json" "$TMP/out.json" 2>&1)"

if ! grep -q '"StatusCode": 200' <<<"$RESP"; then
  echo "❌ Fallo la invocacion:"; echo "$RESP" | sed 's/^/   /'; exit 1
fi

SENT="$(python3 -c "import json;print(json.load(open('$TMP/out.json')).get('sent',0))" 2>/dev/null || echo 0)"

if [[ "$SENT" == "1" ]]; then
  echo "✅ Mensaje enviado. Revisa tu canal de Slack."
else
  echo "❌ La Lambda no pudo entregar el mensaje. Revisa el log:"
  echo "   aws logs tail /aws/lambda/$FN --since 5m"
  python3 -c "import json;print('   respuesta:', json.load(open('$TMP/out.json')))" 2>/dev/null
  exit 1
fi
