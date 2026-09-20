"""Orquestador del flujo de diagnostico.

Disparada por EventBridge cuando la alarma de CloudWatch pasa a ALARM:

  1. Extrae el contexto del incidente del evento (alarma, metrica, umbral, recurso, hora).
  2. Arma el prompt inicial e invoca el harness de Amazon Bedrock AgentCore.
  3. Imprime el trace de razonamiento del agente en CloudWatch Logs en formato
     legible, para poder seguirlo con `aws logs tail --follow` durante la charla.
  4. Invoca la Lambda `notify` con la respuesta final, que publica en SNS.

Migrado desde Bedrock Agents Classic: antes se usaba el cliente
`bedrock-agent-runtime` con InvokeAgent sobre un alias. Ahora se usa el plano de
datos `bedrock-agentcore` con la operacion InvokeHarness, que devuelve un event
stream tipado estilo Converse (messageStart / contentBlockStart /
contentBlockDelta / contentBlockStop / messageStop / metadata).

El modelo, el system prompt y las herramientas NO se mandan en la llamada: estan
configurados en el harness desde Terraform, que es la fuente de verdad. La API
permite sobrescribirlos por invocacion, pero aqui no se usa esa via.

Tambien acepta una invocacion manual con {"prompt": "..."} para ensayar la demo
sin tener que romper el ambiente.
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError, UnknownServiceError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# La investigacion puede tardar: subimos el timeout de lectura y desactivamos
# reintentos para no lanzar dos investigaciones en paralelo por un timeout
# transitorio.
_AGENTCORE_CONFIG = Config(read_timeout=900, connect_timeout=10, retries={"max_attempts": 0})

lambda_client = boto3.client("lambda")

HARNESS_ARN = os.environ["HARNESS_ARN"]
NOTIFY_FUNCTION_NAME = os.environ["NOTIFY_FUNCTION_NAME"]
TARGET_GROUP_ARN = os.environ.get("TARGET_GROUP_ARN", "")
LOAD_BALANCER_ARN = os.environ.get("LOAD_BALANCER_ARN", "")
LOAD_BALANCER_NAME = os.environ.get("LOAD_BALANCER_NAME", "")
INSTANCE_IDS = os.environ.get("INSTANCE_IDS", "")
ALB_SECURITY_GROUP_ID = os.environ.get("ALB_SECURITY_GROUP_ID", "")
APP_SECURITY_GROUP_ID = os.environ.get("APP_SECURITY_GROUP_ID", "")
FLOW_LOG_GROUP_NAME = os.environ.get("FLOW_LOG_GROUP_NAME", "")
LOOKBACK_MINUTES = os.environ.get("CLOUDTRAIL_LOOKBACK_MINUTES", "60")

SEPARATOR = "=" * 78
SUB_SEPARATOR = "-" * 78

# Motivos de parada que significan que la investigacion quedo incompleta.
TRUNCATING_STOP_REASONS = {
    "max_tokens", "max_iterations_exceeded", "max_output_tokens_exceeded",
    "timeout_exceeded", "model_context_window_exceeded", "interrupted",
    "partial_turn", "content_filtered", "malformed_model_output",
    "malformed_tool_use",
}


def _agentcore_client():
    """Cliente del plano de datos de AgentCore.

    Se crea de forma perezosa para poder dar un mensaje accionable si el boto3
    que trae el runtime de Lambda es anterior a AgentCore.
    """
    try:
        return boto3.client("bedrock-agentcore", config=_AGENTCORE_CONFIG)
    except UnknownServiceError as exc:
        raise RuntimeError(
            "El boto3 incluido en este runtime de Lambda no conoce el servicio "
            "'bedrock-agentcore'. Adjunta una layer con un boto3 reciente o "
            "empaqueta boto3 en el zip de la funcion. Detalle: " + str(exc)
        ) from exc


# ---------------------------------------------------------------------------
# 1. Contexto del incidente
# ---------------------------------------------------------------------------

def extract_incident(event: dict) -> dict:
    """Normaliza el evento de EventBridge a un dict plano con el contexto."""
    detail = event.get("detail", {}) or {}
    state = detail.get("state", {}) or {}
    configuration = detail.get("configuration", {}) or {}

    metric_name = ""
    threshold = ""
    namespace = ""
    dimensions: dict = {}

    for metric in configuration.get("metrics", []) or []:
        metric_stat = metric.get("metricStat")
        if not metric_stat:
            continue
        metric_info = metric_stat.get("metric", {})
        metric_name = metric_info.get("name", "")
        namespace = metric_info.get("namespace", "")
        dimensions = metric_info.get("dimensions", {}) or {}
        break

    # El umbral solo aparece dentro del texto de `reason`; lo dejamos como viene
    # y ademas pasamos el reason completo, que el modelo sabe interpretar.
    return {
        "alarm_name": detail.get("alarmName", "desconocida"),
        "alarm_arn": (event.get("resources") or [""])[0],
        "state": state.get("value", "ALARM"),
        "state_reason": state.get("reason", ""),
        "triggered_at": state.get("timestamp") or event.get("time") or datetime.now(timezone.utc).isoformat(),
        "metric_name": metric_name or "UnHealthyHostCount",
        "namespace": namespace or "AWS/ApplicationELB",
        "dimensions": dimensions,
        "threshold": threshold or "> 0",
        "description": configuration.get("description", ""),
    }


def build_prompt(incident: dict) -> str:
    return f"""Se disparo una alarma de CloudWatch en el ambiente de produccion. Investiga y explica la causa raiz.

DATOS DE LA ALARMA
- Nombre: {incident['alarm_name']}
- ARN: {incident['alarm_arn']}
- Estado: {incident['state']}
- Motivo reportado: {incident['state_reason']}
- Metrica: {incident['namespace']} / {incident['metric_name']}
- Dimensiones: {json.dumps(incident['dimensions'], ensure_ascii=False)}
- Momento del disparo (UTC): {incident['triggered_at']}

RECURSOS INVOLUCRADOS
- Target Group: {TARGET_GROUP_ARN}
- Load Balancer: {LOAD_BALANCER_NAME} ({LOAD_BALANCER_ARN})
- Security Group del ALB: {ALB_SECURITY_GROUP_ID}
- Security Group de los targets: {APP_SECURITY_GROUP_ID}
- Instancias target: {INSTANCE_IDS or 'no informadas'}
- Log group con VPC Flow Logs: {FLOW_LOG_GROUP_NAME}

Investiga en este orden: primero el estado actual de los recursos, despues los cambios
recientes en CloudTrail en los ultimos {LOOKBACK_MINUTES} minutos, y por ultimo los logs.
Entrega tu conclusion en el formato indicado en tus instrucciones."""

# ---------------------------------------------------------------------------
# 2. Logging legible del trace
#
# InvokeHarness devuelve un event stream tipado. Los bloques de contenido llegan
# troceados en deltas y se identifican por contentBlockIndex, asi que se
# acumulan y se imprimen enteros al recibir su contentBlockStop. De otro modo el
# log quedaria con una linea por token, ilegible al proyectarlo.
# ---------------------------------------------------------------------------

def _log_block(title: str, content: str) -> None:
    logger.info("\n%s\n%s\n%s\n%s", SUB_SEPARATOR, title, SUB_SEPARATOR, content)


def _truncate(value, limit: int = 4000) -> str:
    text = value if isinstance(value, str) else json.dumps(value, default=str, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit] + "\n[...truncado en el log...]"


def _pretty(text: str) -> str:
    """Re-indenta si el contenido es JSON; si no, lo deja como esta.

    Proyectado en una charla, la diferencia entre un JSON escapado en una linea
    y uno indentado es enorme.
    """
    try:
        return json.dumps(json.loads(text), indent=2, ensure_ascii=False)
    except (json.JSONDecodeError, TypeError):
        return text


def _flush_block(block: dict, step: int) -> str:
    """Imprime un bloque de contenido completo. Devuelve el texto que aporte."""
    kind = block.get("kind", "text")
    body = "".join(block.get("buf", []))

    if kind == "reasoning":
        if body.strip():
            _log_block(f"[PASO {step}] RAZONAMIENTO DEL AGENTE", body)
        return ""

    if kind == "tool_use":
        # El input llega troceado como string JSON a lo largo de varios deltas.
        _log_block(
            f"[PASO {step}] LLAMADA A HERRAMIENTA",
            f"Herramienta : {block.get('name', 'desconocida')}\n"
            f"Argumentos  : {_truncate(_pretty(body) if body.strip() else '{}', 1500)}",
        )
        return ""

    if kind == "tool_result":
        header = f"[PASO {step}] RESPUESTA DE LA HERRAMIENTA"
        if block.get("status") == "error":
            header += " (ERROR)"
        _log_block(header, _truncate(_pretty(body)))
        return ""

    if body.strip():
        _log_block(f"[PASO {step}] RESPUESTA DEL AGENTE", body)
    return body


def _consume_stream(stream) -> str:
    """Recorre el event stream de InvokeHarness y devuelve la respuesta final.

    Se sigue la frontera de mensajes: el texto del mensaje que termina con
    stopReason 'end_turn' es el diagnostico. Asi no se confunde un comentario
    intermedio del agente con su conclusion.
    """
    blocks: dict[int, dict] = {}
    message_text: list[str] = []
    last_message_text = ""
    final_answer = ""
    step = 0

    for event in stream:
        if "messageStart" in event:
            message_text = []
            blocks = {}
            continue

        if "contentBlockStart" in event:
            payload = event["contentBlockStart"]
            index = payload["contentBlockIndex"]
            start = payload.get("start", {})
            if "toolUse" in start:
                tool_use = start["toolUse"]
                blocks[index] = {"kind": "tool_use", "name": tool_use.get("name"), "buf": []}
            elif "toolResult" in start:
                tool_result = start["toolResult"]
                blocks[index] = {"kind": "tool_result", "status": tool_result.get("status"), "buf": []}
            continue

        if "contentBlockDelta" in event:
            payload = event["contentBlockDelta"]
            index = payload["contentBlockIndex"]
            delta = payload.get("delta", {})
            block = blocks.setdefault(index, {"kind": "text", "buf": []})

            if "text" in delta:
                block["buf"].append(delta["text"])
            elif "toolUse" in delta:
                block["kind"] = "tool_use"
                block["buf"].append(delta["toolUse"].get("input", ""))
            elif "toolResult" in delta:
                block["kind"] = "tool_result"
                for part in delta["toolResult"] or []:
                    if "text" in part:
                        block["buf"].append(part["text"])
                    elif "json" in part:
                        block["buf"].append(json.dumps(part["json"], default=str, ensure_ascii=False))
            elif "reasoningContent" in delta:
                block["kind"] = "reasoning"
                reasoning = delta["reasoningContent"]
                if "text" in reasoning:
                    block["buf"].append(reasoning["text"])
            continue

        if "contentBlockStop" in event:
            index = event["contentBlockStop"]["contentBlockIndex"]
            block = blocks.pop(index, None)
            if block is None:
                continue
            step += 1
            try:
                text = _flush_block(block, step)
            except Exception:  # noqa: BLE001
                # Un bloque con forma inesperada no debe abortar la investigacion.
                logger.exception("No se pudo formatear el bloque %s", index)
                text = ""
            if text:
                message_text.append(text)
            continue

        if "messageStop" in event:
            stop_reason = event["messageStop"].get("stopReason")
            logger.info("Fin de mensaje. stopReason=%s", stop_reason)
            joined = "".join(message_text).strip()
            if joined:
                last_message_text = joined
            if stop_reason == "end_turn" and joined:
                final_answer = joined
            elif stop_reason in TRUNCATING_STOP_REASONS:
                logger.warning(
                    "El agente se detuvo por '%s': la investigacion puede estar incompleta.",
                    stop_reason,
                )
            continue

        if "metadata" in event:
            usage = event["metadata"].get("usage", {})
            logger.info("Consumo de tokens: %s", json.dumps(usage, default=str))
            continue

        # Excepciones modeladas dentro del propio stream.
        for key in ("internalServerException", "validationException", "runtimeClientError"):
            if key in event:
                detail = event[key]
                message = detail.get("message", "") if isinstance(detail, dict) else str(detail)
                _log_block(f"[FALLO] {key}", _truncate(detail))
                raise RuntimeError(f"{key}: {message}")

        logger.info("Evento de stream no reconocido: %s", _truncate(event, 1000))

    return final_answer or last_message_text


# ---------------------------------------------------------------------------
# 3. Invocacion del agente
# ---------------------------------------------------------------------------

def invoke_agent(prompt: str, session_id: str) -> str:
    logger.info(
        "\n%s\nINVOCANDO BEDROCK AGENTCORE (InvokeHarness)\n%s\nHarness : %s\nSesion  : %s\n%s\nPROMPT INICIAL:\n%s\n%s",
        SEPARATOR, SEPARATOR, HARNESS_ARN, session_id, SUB_SEPARATOR, prompt, SEPARATOR,
    )

    client = _agentcore_client()
    response = client.invoke_harness(
        harnessArn=HARNESS_ARN,
        runtimeSessionId=session_id,
        messages=[{"role": "user", "content": [{"text": prompt}]}],
    )

    answer = _consume_stream(response["stream"]).strip()
    logger.info("\n%s\nDIAGNOSTICO FINAL\n%s\n%s\n%s", SEPARATOR, SEPARATOR, answer, SEPARATOR)
    return answer


# ---------------------------------------------------------------------------
# 4. Handler
# ---------------------------------------------------------------------------

def handler(event, context):
    logger.info("Evento recibido:\n%s", json.dumps(event, default=str, ensure_ascii=False)[:4000])

    # Modo ensayo: invocacion manual con un prompt propio.
    if "prompt" in event:
        incident = {
            "alarm_name": event.get("alarm_name", "invocacion-manual"),
            "alarm_arn": "",
            "metric_name": "n/a",
            "threshold": "n/a",
            "triggered_at": datetime.now(timezone.utc).isoformat(),
        }
        prompt = event["prompt"]
    else:
        incident = extract_incident(event)
        prompt = build_prompt(incident)

    # InvokeHarness exige un runtimeSessionId de al menos 33 caracteres;
    # un UUID4 en formato canonico tiene 36.
    session_id = str(uuid.uuid4())
    status = "ok"

    try:
        diagnosis = invoke_agent(prompt, session_id)
        if not diagnosis:
            status = "sin_respuesta"
            diagnosis = "El agente termino sin producir una respuesta final. Revisa el trace en CloudWatch Logs."
    except ClientError as exc:
        status = "error"
        code = exc.response["Error"]["Code"]
        diagnosis = f"No se pudo completar la investigacion. Error de AgentCore: {code} - {exc.response['Error']['Message']}"
        logger.exception("InvokeHarness fallo")
    except Exception as exc:  # noqa: BLE001
        status = "error"
        diagnosis = f"No se pudo completar la investigacion. Error inesperado: {exc}"
        logger.exception("Fallo inesperado invocando al agente")

    payload = {
        "alarm_name": incident.get("alarm_name"),
        "resource_arn": TARGET_GROUP_ARN,
        "metric_name": incident.get("metric_name"),
        "threshold": incident.get("threshold"),
        "triggered_at": incident.get("triggered_at"),
        "session_id": session_id,
        "status": status,
        "diagnosis": diagnosis,
    }

    # Siempre se notifica, incluso si la investigacion fallo: en una demo en vivo
    # es peor un silencio que un mensaje diciendo que algo salio mal.
    try:
        lambda_client.invoke(
            FunctionName=NOTIFY_FUNCTION_NAME,
            InvocationType="RequestResponse",
            Payload=json.dumps(payload).encode("utf-8"),
        )
        logger.info("Lambda notify invocada correctamente")
    except ClientError:
        logger.exception("No se pudo invocar la Lambda notify")

    return {"status": status, "session_id": session_id, "diagnosis": diagnosis}
