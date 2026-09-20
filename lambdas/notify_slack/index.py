"""Reenvia a un Incoming Webhook de Slack los mensajes que llegan al topic SNS.

Usa urllib de la libreria estandar para no necesitar dependencias ni layers.
Si SLACK_WEBHOOK_URL esta vacio (el default de Terraform), la funcion solo
loguea el mensaje y termina bien: asi el `apply` funciona sin configurar Slack.
"""

import json
import logging
import os
import urllib.error
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

WEBHOOK_URL = os.environ.get("SLACK_WEBHOOK_URL", "").strip()
TIMEOUT_SECONDS = 10
MAX_BLOCK_CHARS = 2900  # limite de Slack por bloque de texto: 3000


def _to_slack_payload(subject: str, message: str) -> dict:
    body = message if len(message) <= MAX_BLOCK_CHARS else message[:MAX_BLOCK_CHARS] + "\n[...truncado...]"
    return {
        "text": subject or "Diagnostico de incidente",
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": (subject or "Incidente")[:150]},
            },
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": f"```{body}```"},
            },
        ],
    }


def _post(payload: dict) -> int:
    request = urllib.request.Request(
        WEBHOOK_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return response.status


def handler(event, context):
    records = event.get("Records", [])
    logger.info("Recibidos %d registros de SNS", len(records))

    sent = 0
    for record in records:
        sns_message = record.get("Sns", {})
        subject = sns_message.get("Subject") or "Diagnostico de incidente"
        message = sns_message.get("Message", "")

        if not WEBHOOK_URL:
            logger.warning(
                "SLACK_WEBHOOK_URL no configurado; no se envia a Slack. Mensaje:\n%s",
                message,
            )
            continue

        try:
            status = _post(_to_slack_payload(subject, message))
            logger.info("Slack respondio %s", status)
            sent += 1
        except urllib.error.HTTPError as exc:
            # No relanzamos: un webhook mal configurado no debe romper la demo,
            # el email de SNS sigue llegando igual.
            logger.error("Slack devolvio %s: %s", exc.code, exc.read().decode("utf-8", "ignore"))
        except Exception:
            logger.exception("Fallo enviando a Slack")

    return {"status": "done", "sent": sent, "received": len(records)}
