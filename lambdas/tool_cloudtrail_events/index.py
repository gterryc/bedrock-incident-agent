"""Herramienta `tool_cloudtrail_events`, expuesta como MCP por AgentCore Gateway.

Busca cambios de configuracion recientes en CloudTrail.

Se usa `cloudtrail:LookupEvents` sobre el Event History (90 dias) en vez de
Athena a proposito: no requiere crear un Trail, ni bucket S3, ni tabla Glue,
y por lo tanto no agrega costo fijo a la demo. La contrapartida es que solo ve
eventos de management y que la API es lenta si la ventana es muy grande, por
eso la ventana por defecto es de 60 minutos.

Una sola funcion: lookup_events(minutes, event_names, resource_name).
"""

import json
import logging
import os
from datetime import datetime, timedelta, timezone

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

cloudtrail = boto3.client("cloudtrail")

DEFAULT_LOOKBACK_MINUTES = int(os.environ.get("DEFAULT_LOOKBACK_MINUTES", "60"))
MAX_LOOKBACK_MINUTES = 60 * 24 * 7  # una semana: mas alla la API se vuelve muy lenta
MAX_EVENTS = 50

# Eventos que pueden explicar una caida de healthcheck en este escenario.
# Si el agente no filtra, se usan estos.
RELEVANT_EVENT_NAMES = [
    "RevokeSecurityGroupIngress",
    "AuthorizeSecurityGroupIngress",
    "RevokeSecurityGroupEgress",
    "AuthorizeSecurityGroupEgress",
    "ModifyTargetGroup",
    "ModifyTargetGroupAttributes",
    "DeregisterTargets",
    "RegisterTargets",
    "ModifyLoadBalancerAttributes",
    "SetSecurityGroups",
    "ModifyListener",
    "ModifyInstanceAttribute",
    "StopInstances",
    "TerminateInstances",
]


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


def _lookup_by_event_name(event_name: str, start: datetime, end: datetime) -> list:
    """CloudTrail solo admite UN atributo de busqueda por llamada."""
    events = []
    paginator = cloudtrail.get_paginator("lookup_events")
    pages = paginator.paginate(
        LookupAttributes=[{"AttributeKey": "EventName", "AttributeValue": event_name}],
        StartTime=start,
        EndTime=end,
        PaginationConfig={"MaxItems": MAX_EVENTS},
    )
    for page in pages:
        events.extend(page.get("Events", []))
    return events


def _lookup_by_resource(resource_name: str, start: datetime, end: datetime) -> list:
    events = []
    paginator = cloudtrail.get_paginator("lookup_events")
    pages = paginator.paginate(
        LookupAttributes=[{"AttributeKey": "ResourceName", "AttributeValue": resource_name}],
        StartTime=start,
        EndTime=end,
        PaginationConfig={"MaxItems": MAX_EVENTS},
    )
    for page in pages:
        events.extend(page.get("Events", []))
    return events


def _summarize(raw_event: dict) -> dict:
    """Extrae del CloudTrailEvent solo lo que le sirve al modelo."""
    detail = {}
    try:
        detail = json.loads(raw_event.get("CloudTrailEvent", "{}"))
    except (json.JSONDecodeError, TypeError):
        pass

    identity = detail.get("userIdentity", {})
    return {
        "event_time": raw_event.get("EventTime"),
        "event_name": raw_event.get("EventName"),
        "event_source": raw_event.get("EventSource"),
        "username": raw_event.get("Username"),
        "principal_type": identity.get("type"),
        "principal_arn": identity.get("arn"),
        "source_ip": detail.get("sourceIPAddress"),
        "user_agent": detail.get("userAgent"),
        "aws_region": detail.get("awsRegion"),
        "error_code": detail.get("errorCode"),
        "resources": [
            {"type": r.get("ResourceType"), "name": r.get("ResourceName")}
            for r in raw_event.get("Resources", [])
        ],
        # Los parametros de la request son la evidencia concreta: aqui aparece
        # el groupId y la regla exacta que se revoco.
        "request_parameters": detail.get("requestParameters"),
    }


def lookup_events(params: dict) -> dict:
    minutes = int(params.get("minutes") or DEFAULT_LOOKBACK_MINUTES)
    minutes = max(1, min(minutes, MAX_LOOKBACK_MINUTES))

    end = datetime.now(timezone.utc)
    start = end - timedelta(minutes=minutes)

    resource_name = params.get("resource_name")
    raw_names = params.get("event_names")
    event_names = [n.strip() for n in raw_names.split(",") if n.strip()] if raw_names else RELEVANT_EVENT_NAMES

    collected: dict[str, dict] = {}

    if resource_name:
        # Filtrar por recurso es lo mas preciso cuando el agente ya sabe el sg-xxxx.
        for raw in _lookup_by_resource(resource_name, start, end):
            collected[raw["EventId"]] = raw
    else:
        for name in event_names:
            try:
                for raw in _lookup_by_event_name(name, start, end):
                    collected[raw["EventId"]] = raw
            except ClientError:
                logger.exception("Fallo buscando eventos %s", name)

    events = sorted(
        (_summarize(raw) for raw in collected.values()),
        key=lambda e: e["event_time"] or datetime.min.replace(tzinfo=timezone.utc),
        reverse=True,
    )[:MAX_EVENTS]

    return {
        "window": {
            "start": start.isoformat(),
            "end": end.isoformat(),
            "minutes": minutes,
        },
        "filter": {"resource_name": resource_name, "event_names": None if resource_name else event_names},
        "event_count": len(events),
        "events": events,
        "note": (
            "Sin resultados no significa que no hubo cambios: puede que el cambio quede fuera de la "
            "ventana o que CloudTrail tarde hasta 15 minutos en indexar el evento."
            if not events
            else None
        ),
    }


FUNCTIONS = {"lookup_events": lookup_events}


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
