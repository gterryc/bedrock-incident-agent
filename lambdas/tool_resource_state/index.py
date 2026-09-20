"""Herramienta `tool_resource_state`, expuesta como MCP por AgentCore Gateway.

Devuelve el estado ACTUAL de los recursos del incidente. Tres funciones:

  - describe_target_health   -> elbv2:DescribeTargetHealth
  - describe_security_groups -> ec2:DescribeSecurityGroups
  - describe_load_balancers  -> elbv2:DescribeLoadBalancers

Todas aceptan sus parametros como opcionales: si el agente no los envia se usan
los valores por defecto que Terraform inyecta como variables de entorno, que
apuntan a los recursos de esta demo. Asi el agente puede investigar sin tener
que adivinar ARNs.

La respuesta se devuelve como JSON dentro del campo TEXT, que es lo que espera
el formato de function schema de Bedrock Agents.
"""

import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

elbv2 = boto3.client("elbv2")
ec2 = boto3.client("ec2")

DEFAULT_TARGET_GROUP_ARN = os.environ.get("DEFAULT_TARGET_GROUP_ARN", "")
DEFAULT_LOAD_BALANCER_ARN = os.environ.get("DEFAULT_LOAD_BALANCER_ARN", "")
# Lista separada por comas: SG del ALB y SG de la app.
DEFAULT_SECURITY_GROUP_IDS = os.environ.get("DEFAULT_SECURITY_GROUP_IDS", "")


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


def _split(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


# --------------------------------------------------------------------------
# Funciones expuestas al agente
# --------------------------------------------------------------------------

def describe_target_health(params: dict) -> dict:
    target_group_arn = params.get("target_group_arn") or DEFAULT_TARGET_GROUP_ARN
    if not target_group_arn:
        return {"error": "No se indico target_group_arn y no hay valor por defecto configurado."}

    response = elbv2.describe_target_health(TargetGroupArn=target_group_arn)

    targets = []
    for item in response.get("TargetHealthDescriptions", []):
        health = item.get("TargetHealth", {})
        targets.append(
            {
                "target_id": item.get("Target", {}).get("Id"),
                "port": item.get("Target", {}).get("Port"),
                "state": health.get("State"),
                "reason": health.get("Reason"),
                "description": health.get("Description"),
            }
        )

    unhealthy = [t for t in targets if t["state"] != "healthy"]
    return {
        "target_group_arn": target_group_arn,
        "total_targets": len(targets),
        "unhealthy_count": len(unhealthy),
        "targets": targets,
    }


def describe_security_groups(params: dict) -> dict:
    raw_ids = params.get("security_group_ids") or DEFAULT_SECURITY_GROUP_IDS
    group_ids = _split(raw_ids)
    if not group_ids:
        return {"error": "No se indicaron security_group_ids y no hay valores por defecto."}

    response = ec2.describe_security_groups(GroupIds=group_ids)

    groups = []
    for group in response.get("SecurityGroups", []):
        groups.append(
            {
                "group_id": group.get("GroupId"),
                "group_name": group.get("GroupName"),
                "description": group.get("Description"),
                "vpc_id": group.get("VpcId"),
                "ingress_rules": _format_rules(group.get("IpPermissions", [])),
                "egress_rules": _format_rules(group.get("IpPermissionsEgress", [])),
            }
        )

    return {"security_groups": groups}


def describe_load_balancers(params: dict) -> dict:
    load_balancer_arn = params.get("load_balancer_arn") or DEFAULT_LOAD_BALANCER_ARN
    if not load_balancer_arn:
        return {"error": "No se indico load_balancer_arn y no hay valor por defecto configurado."}

    response = elbv2.describe_load_balancers(LoadBalancerArns=[load_balancer_arn])

    balancers = []
    for lb in response.get("LoadBalancers", []):
        balancers.append(
            {
                "arn": lb.get("LoadBalancerArn"),
                "name": lb.get("LoadBalancerName"),
                "dns_name": lb.get("DNSName"),
                "scheme": lb.get("Scheme"),
                "state": lb.get("State", {}).get("Code"),
                "vpc_id": lb.get("VpcId"),
                "security_groups": lb.get("SecurityGroups", []),
                "availability_zones": [az.get("ZoneName") for az in lb.get("AvailabilityZones", [])],
            }
        )

    return {"load_balancers": balancers}


def _format_rules(permissions: list) -> list:
    """Normaliza reglas de SG a algo compacto y facil de leer para el modelo."""
    rules = []
    for perm in permissions:
        protocol = perm.get("IpProtocol")
        rules.append(
            {
                "protocol": "all" if protocol == "-1" else protocol,
                "from_port": perm.get("FromPort"),
                "to_port": perm.get("ToPort"),
                "cidr_blocks": [r.get("CidrIp") for r in perm.get("IpRanges", [])],
                "source_security_groups": [r.get("GroupId") for r in perm.get("UserIdGroupPairs", [])],
                "description": next(
                    (
                        r.get("Description")
                        for r in perm.get("IpRanges", []) + perm.get("UserIdGroupPairs", [])
                        if r.get("Description")
                    ),
                    None,
                ),
            }
        )
    return rules


FUNCTIONS = {
    "describe_target_health": describe_target_health,
    "describe_security_groups": describe_security_groups,
    "describe_load_balancers": describe_load_balancers,
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
