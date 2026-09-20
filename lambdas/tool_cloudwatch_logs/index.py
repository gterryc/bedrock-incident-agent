"""Herramienta `tool_cloudwatch_logs`, expuesta como MCP por AgentCore Gateway.

Ejecuta consultas de CloudWatch Logs Insights y espera el resultado.

El log group por defecto es el de VPC Flow Logs de la VPC de la demo: cuando se
quita la regla de ingress, los intentos de healthcheck del ALB hacia el puerto
80 de las instancias aparecen ahi como REJECT. Esa es la evidencia mas directa
de la causa raiz.

Dos funciones:
  - run_insights_query : consulta libre, con la query que arme el agente
  - list_log_groups    : para que el agente descubra que log groups existen
"""

import json
import logging
import os
import time

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

logs = boto3.client("logs")

DEFAULT_LOG_GROUP = os.environ.get("DEFAULT_LOG_GROUP", "")
LOG_GROUP_PREFIX = os.environ.get("LOG_GROUP_PREFIX", "")
DEFAULT_MINUTES = int(os.environ.get("DEFAULT_LOOKBACK_MINUTES", "60"))

QUERY_TIMEOUT_SECONDS = 60
POLL_INTERVAL_SECONDS = 2
MAX_RESULTS = 50

# Query por defecto: rechazos de trafico en los flow logs, lo mas util para
# este escenario. El agente puede reemplazarla si quiere mirar otra cosa.
DEFAULT_QUERY = (
    "fields @timestamp, srcAddr, dstAddr, dstPort, protocol, action "
    "| filter action = 'REJECT' "
    "| sort @timestamp desc "
    "| limit 50"
)


def _tool_name(event: dict, context) -> str:
    """Resuelve que funcion se pidio.

    AgentCore Gateway manda el nombre de la tool en el client context de la
    invocacion, prefijado con el nombre del target y separado por tres guiones
    bajos: "tool-resource-state___describe_target_health".

    Se aceptan ademas dos formas alternativas para no quedar atados a un unico
    envelope: el nombre plano dentro del evento (util para invocar la Lambda a
    mano en una prueba) y el campo `function` del formato viejo de Action
    Groups.
    """
    custom = {}
    client_context = getattr(context, "client_context", None)
    if client_context is not None:
        custom = getattr(client_context, "custom", None) or {}

    for key in ("bedrockAgentCoreToolName", "bedrockagentcoreToolName", "toolName", "name"):
        raw = custom.get(key)
        if raw:
            return str(raw).split("___")[-1]

    for key in ("toolName", "name", "function"):
        raw = event.get(key)
        if raw:
            return str(raw).split("___")[-1]

    return ""


# Claves del envelope que nunca son argumentos de la herramienta.
_RESERVED_KEYS = frozenset({
    "toolName", "name", "function", "actionGroup", "messageVersion",
    "sessionAttributes", "promptSessionAttributes", "agent", "parameters",
})


def _params(event: dict) -> dict:
    """Devuelve los argumentos de la herramienta como un dict plano.

    AgentCore Gateway entrega los argumentos directamente en el cuerpo del
    evento, ya tipados segun el input_schema. Se mantiene la compatibilidad con
    la lista [{name, type, value}] que usaban los Action Groups.
    """
    if isinstance(event.get("parameters"), list):
        return {
            p["name"]: p.get("value")
            for p in event["parameters"]
            if isinstance(p, dict) and p.get("name") and p.get("value") not in (None, "")
        }

    body = event
    for key in ("arguments", "input", "body"):
        if isinstance(event.get(key), dict):
            body = event[key]
            break

    return {k: v for k, v in body.items() if k not in _RESERVED_KEYS and v not in (None, "")}


def run_insights_query(params: dict) -> dict:
    log_group = params.get("log_group_name") or DEFAULT_LOG_GROUP
    if not log_group:
        return {"error": "No se indico log_group_name y no hay valor por defecto configurado."}

    query = params.get("query_string") or DEFAULT_QUERY
    minutes = max(1, min(int(params.get("minutes") or DEFAULT_MINUTES), 60 * 24))

    end = int(time.time())
    start = end - minutes * 60

    start_response = logs.start_query(
        logGroupName=log_group,
        startTime=start,
        endTime=end,
        queryString=query,
        limit=MAX_RESULTS,
    )
    query_id = start_response["queryId"]
    logger.info("Logs Insights query %s lanzada sobre %s", query_id, log_group)

    deadline = time.time() + QUERY_TIMEOUT_SECONDS
    status = "Running"
    results: list = []

    while time.time() < deadline:
        outcome = logs.get_query_results(queryId=query_id)
        status = outcome["status"]
        if status in ("Complete", "Failed", "Cancelled", "Timeout"):
            results = outcome.get("results", [])
            break
        time.sleep(POLL_INTERVAL_SECONDS)
    else:
        # Se agoto el tiempo del lado de la Lambda: cancelamos para no dejarla corriendo.
        try:
            logs.stop_query(queryId=query_id)
        except ClientError:
            logger.warning("No se pudo cancelar la query %s", query_id)
        return {
            "log_group": log_group,
            "query": query,
            "status": "Timeout",
            "error": f"La query no termino en {QUERY_TIMEOUT_SECONDS}s.",
        }

    # Cada fila viene como [{field, value}, ...]; la aplanamos a un dict.
    rows = [{item["field"]: item["value"] for item in row if item["field"] != "@ptr"} for row in results]

    return {
        "log_group": log_group,
        "query": query,
        "window": {"minutes": minutes, "start_epoch": start, "end_epoch": end},
        "status": status,
        "row_count": len(rows),
        "results": rows,
        "note": (
            "Sin resultados. Puede ser que no haya trafico en la ventana o que la query no aplique "
            "al formato de este log group."
            if not rows
            else None
        ),
    }


def list_log_groups(params: dict) -> dict:
    prefix = params.get("prefix") or LOG_GROUP_PREFIX
    kwargs = {"limit": 50}
    if prefix:
        kwargs["logGroupNamePrefix"] = prefix

    response = logs.describe_log_groups(**kwargs)
    groups = [
        {"name": g.get("logGroupName"), "stored_bytes": g.get("storedBytes")}
        for g in response.get("logGroups", [])
    ]
    return {"prefix": prefix or "(sin filtro)", "count": len(groups), "log_groups": groups}


FUNCTIONS = {
    "run_insights_query": run_insights_query,
    "list_log_groups": list_log_groups,
}


def handler(event, context):
    """Punto de entrada de la herramienta.

    Contrato con AgentCore Gateway: entra un objeto con los argumentos y sale
    el resultado como JSON plano. A diferencia de los Action Groups de Bedrock
    Agents Classic, no hay que envolver la respuesta en
    {messageVersion, response.functionResponse.responseBody}.
    """
    logger.info("Invocacion de herramienta: %s", json.dumps(event, default=str)[:2000])

    function_name = _tool_name(event, context)
    params = _params(event)

    handler_fn = FUNCTIONS.get(function_name)
    if handler_fn is None:
        result = {"error": f"Funcion desconocida: {function_name!r}. Disponibles: {sorted(FUNCTIONS)}"}
    else:
        try:
            result = handler_fn(params)
        except ClientError as exc:
            # Devolvemos el error como dato, no como excepcion: el agente debe
            # poder razonar sobre un permiso faltante o un ARN invalido.
            logger.exception("Error de AWS ejecutando %s", function_name)
            result = {"error": f"Error de AWS: {exc.response['Error']['Code']} - {exc.response['Error']['Message']}"}
        except Exception as exc:  # noqa: BLE001
            logger.exception("Error inesperado ejecutando %s", function_name)
            result = {"error": f"Error inesperado: {exc}"}

    logger.info("Respuesta de %s: %s", function_name, json.dumps(result, default=str, ensure_ascii=False)[:2000])

    # El runtime de Lambda serializa el valor devuelto con json.dumps SIN
    # `default`, y las APIs de AWS devuelven objetos datetime (por ejemplo
    # EventTime de CloudTrail). Sin esta normalizacion la invocacion muere con
    # Runtime.MarshalError y el agente solo ve un fallo opaco de la herramienta.
    return json.loads(json.dumps(result, default=str, ensure_ascii=False))
