"""Publica en SNS el diagnostico final del Bedrock Agent.

La invoca `invoke_agent` de forma sincrona al terminar el flujo. Recibe un dict
con el contexto de la alarma y la respuesta final del agente, y publica un
mensaje ya formateado (texto plano, legible tanto en email como en Slack).
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sns = boto3.client("sns")

TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
MAX_SNS_BYTES = 250_000  # el limite duro de SNS es 256 KB; dejamos margen


def _truncate(text: str, limit: int = MAX_SNS_BYTES) -> str:
    encoded = text.encode("utf-8")
    if len(encoded) <= limit:
        return text
    return encoded[:limit].decode("utf-8", errors="ignore") + "\n\n[...mensaje truncado...]"


def _build_message(event: dict) -> tuple[str, str]:
    alarm_name = event.get("alarm_name", "desconocida")
    resource = event.get("resource_arn", "no informado")
    metric = event.get("metric_name", "no informada")
    threshold = event.get("threshold", "no informado")
    triggered_at = event.get("triggered_at", datetime.now(timezone.utc).isoformat())
    diagnosis = event.get("diagnosis") or "El agente no devolvio una respuesta final."
    status = event.get("status", "ok")

    subject = f"[Incidente] {alarm_name}"[:100]

    lines = [
        "DIAGNOSTICO AUTOMATICO DE INCIDENTE",
        "=" * 40,
        "",
        f"Alarma      : {alarm_name}",
        f"Metrica     : {metric} (umbral: {threshold})",
        f"Recurso     : {resource}",
        f"Disparada   : {triggered_at}",
        f"Estado flujo: {status}",
        "",
        "-" * 40,
        "ANALISIS DEL AGENTE",
        "-" * 40,
        "",
        diagnosis,
        "",
        "-" * 40,
        f"Generado por Amazon Bedrock Agents - {datetime.now(timezone.utc).isoformat()}",
    ]
    return subject, _truncate("\n".join(lines))


def handler(event, context):
    logger.info("Evento recibido: %s", json.dumps(event, default=str)[:2000])

    subject, message = _build_message(event)

    response = sns.publish(
        TopicArn=TOPIC_ARN,
        Subject=subject,
        Message=message,
    )
    logger.info("Publicado en SNS. MessageId=%s", response["MessageId"])

    return {"status": "published", "message_id": response["MessageId"]}
