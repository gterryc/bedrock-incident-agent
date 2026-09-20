# ---------------------------------------------------------------------------
# Amazon Bedrock AgentCore
#
# Migrado desde Bedrock Agents Classic, que dejo de aceptar cuentas nuevas el
# 30/07/2026. El mapeo conceptual es:
#
#   Classic                          AgentCore
#   ------------------------------   --------------------------------------
#   aws_bedrockagent_agent           aws_bedrockagentcore_harness
#   action group (x3)                aws_bedrockagentcore_gateway_target (x3)
#   (no existia)                     aws_bedrockagentcore_gateway  <- entrada MCP
#   agent alias + prepare-agent      (no hacen falta)
#
# Se usa `harness` y no `agent_runtime` porque `agent_runtime` exige un
# `agent_runtime_artifact`: una imagen de contenedor en ECR o codigo en S3, es
# decir, hospedar tu propio codigo de agente. `harness` es la orquestacion
# gestionada: recibe modelo + system prompt + herramientas, que es justo el
# patron que traiamos de Classic.
# ---------------------------------------------------------------------------

locals {
  # OJO: cada recurso de AgentCore valida su nombre con una regla DISTINTA, y el
  # provider solo las comprueba en `plan` cuando el valor viene de una variable.
  # Verificadas contra los validadores del provider:
  #
  #   harness_name          a-z A-Z 0-9 _   empieza con letra, max 40. SIN guion medio.
  #   gateway.name          ^([0-9a-zA-Z][-]?){1,100}$      SIN guion bajo.
  #   gateway_target.name   a-z A-Z 0-9 -   max 50.         SIN guion bajo.
  #
  # Por eso hacen falta dos formas del mismo nombre.
  harness_name = replace(var.name_prefix, "-", "_")
  gateway_name = "${replace(var.name_prefix, "_", "-")}-tools"
}

# ---------------------------------------------------------------------------
# Rol del Gateway: lo unico que necesita es invocar las 3 Lambdas herramienta.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "agentcore_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    # Confused deputy: solo recursos de AgentCore de esta cuenta.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${var.name_prefix}-agentcore-gateway"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

data "aws_iam_policy_document" "gateway" {
  statement {
    sid     = "InvokeToolLambdas"
    actions = ["lambda:InvokeFunction"]
    # Acotado exactamente a las 3 Lambdas herramienta de esta demo.
    resources = [for k, v in aws_lambda_function.tool : v.arn]
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "invoke-tool-lambdas"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

# ---------------------------------------------------------------------------
# Rol de ejecucion del Harness: invoca el modelo y llama al Gateway.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "harness" {
  name               = "${var.name_prefix}-agentcore-harness"
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

data "aws_iam_policy_document" "harness" {
  statement {
    sid     = "InvokeFoundationModel"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    # Con un inference profile cross-region hace falta permitir tanto el perfil
    # como los foundation models subyacentes en las regiones del perfil.
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:${var.aws_region}:${var.account_id}:inference-profile/*",
    ]
  }

  statement {
    sid       = "ResolveInferenceProfile"
    actions   = ["bedrock:GetInferenceProfile", "bedrock:GetFoundationModel"]
    resources = ["*"]
  }

  statement {
    sid     = "CallToolGateway"
    actions = ["bedrock-agentcore:InvokeGateway"]
    resources = [
      aws_bedrockagentcore_gateway.this.gateway_arn,
      "${aws_bedrockagentcore_gateway.this.gateway_arn}/*",
    ]
  }

  # Identidad de carga de trabajo: AgentCore la usa para emitir los tokens
  # internos con los que el harness se autentica contra el gateway.
  statement {
    sid = "WorkloadIdentity"
    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
      "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
    ]
    resources = [
      "arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:workload-identity-directory/default",
      "arn:aws:bedrock-agentcore:${var.aws_region}:${var.account_id}:workload-identity-directory/default/workload-identity/*",
    ]
  }

  statement {
    sid = "Observability"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/bedrock-agentcore/*"]
  }
}

resource "aws_iam_role_policy" "harness" {
  name   = "harness-execution"
  role   = aws_iam_role.harness.id
  policy = data.aws_iam_policy_document.harness.json
}

locals {
  agent_instruction = <<-EOT
    Eres un ingeniero SRE senior especializado en diagnostico de incidentes de infraestructura en AWS.
    Respondes SIEMPRE en espanol, de forma tecnica, concisa y directa.

    Tu tarea es encontrar la causa raiz de la alarma de CloudWatch que se te reporta, apoyandote
    unicamente en las herramientas que tienes disponibles.

    METODO DE INVESTIGACION, en este orden:

    1. ESTADO ACTUAL. Usa tool_resource_state para ver el estado real del recurso afectado:
       describe_target_health para saber cuantos targets estan unhealthy y por que motivo,
       describe_security_groups para inspeccionar las reglas vigentes de los security groups
       involucrados, y describe_load_balancers para el estado del balanceador.
       Presta especial atencion a si el security group de los targets tiene una regla de ingress
       que permita el trafico desde el security group del balanceador en el puerto de la aplicacion.
       Si esa regla no existe, el healthcheck no puede llegar al target.

    2. CAMBIOS RECIENTES. Usa tool_cloudtrail_events para buscar modificaciones de configuracion
       en la ventana de tiempo previa al disparo de la alarma. Te interesan eventos sobre security
       groups, target groups, balanceadores e instancias. Si encuentras un evento relevante, anota
       la hora exacta, quien lo ejecuto y que parametros uso.
       Correlaciona la hora del cambio con la hora del disparo de la alarma.

    3. LOGS. Usa tool_cloudwatch_logs para buscar evidencia en los logs. El log group por defecto
       contiene los VPC Flow Logs de la VPC: los registros con action REJECT hacia el puerto de la
       aplicacion confirman que el trafico esta siendo bloqueado a nivel de red.

    REGLAS QUE NO PUEDES ROMPER:

    - No inventes datos. Si una herramienta no devuelve informacion, dilo explicitamente en lugar
      de suponer. Nunca cites IDs, horas, nombres de usuario o eventos que no hayas obtenido de una
      herramienta.
    - Distingue con claridad entre lo que observaste y lo que infieres.
    - Si la evidencia no alcanza para una conclusion firme, di que la hipotesis es tentativa y
      explica que dato faltaria para confirmarla.
    - No ejecutes ni propongas ejecutar cambios: solo recomiendas.
    - Se eficiente: en cuanto tengas evidencia suficiente para sostener una causa raiz, deja de
      investigar y entrega la conclusion. No hace falta agotar todas las herramientas ni descender
      al detalle de direcciones IP individuales si el patron ya es claro. Es preferible una
      conclusion firme y rapida que un analisis exhaustivo que no llega a cerrar.

    FORMATO DE TU RESPUESTA FINAL, con estos cuatro encabezados y nada mas:

    ## Resumen
    Dos o tres frases explicando que esta pasando, en lenguaje entendible.

    ## Causa raiz
    La hipotesis concreta, indicando el nivel de confianza (alta, media o baja).

    ## Evidencia
    Lista de hallazgos con el dato exacto y de que herramienta salio. Incluye IDs de recursos,
    marcas de tiempo y nombres de eventos.

    ## Remediacion recomendada
    Los pasos concretos para restablecer el servicio, y una recomendacion de prevencion.
  EOT
}
# ---------------------------------------------------------------------------
# Gateway: punto de entrada MCP a las herramientas.
#
# authorizer_type = AWS_IAM evita tener que montar un pool de Cognito o un
# proveedor OAuth solo para que el agente pueda llamar a sus propias tools:
# el harness se autentica con SigV4 usando su rol de ejecucion.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway" "this" {
  name            = local.gateway_name
  description     = "Herramientas de diagnostico de incidentes expuestas como MCP."
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "AWS_IAM"

  # DEBUG hace que el gateway devuelva el error real de la Lambda en vez de un
  # mensaje generico. Vale mucho cuando algo falla en vivo durante la charla.
  exception_level = "DEBUG"

  protocol_configuration {
    mcp {
      instructions = "Herramientas de solo lectura para diagnosticar incidentes de infraestructura en AWS: estado de recursos, cambios recientes en CloudTrail y consultas a CloudWatch Logs."
    }
  }
}

# ---------------------------------------------------------------------------
# Targets: una Lambda por target, cada una exponiendo sus funciones como tools.
#
# Los esquemas replican exactamente los que tenian los action groups de Classic.
# Todos los parametros siguen siendo opcionales: las Lambdas resuelven los
# valores por defecto desde variables de entorno que inyecta Terraform.
#
# El gateway invoca las Lambdas con su propio rol (gateway_iam_role).
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway_target" "resource_state" {
  name               = "tool-resource-state"
  description        = "Consulta el estado actual de target groups, security groups y balanceadores."
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tool["tool_resource_state"].arn

        tool_schema {
          inline_payload {
            name        = "describe_target_health"
            description = "Devuelve el estado de salud de cada target del target group, con el motivo y la descripcion del fallo. Usala primero para confirmar cuantos targets estan unhealthy."

            input_schema {
              type = "object"

              property {
                name        = "target_group_arn"
                type        = "string"
                description = "ARN del target group. Si se omite se usa el target group del incidente."
                required    = false
              }
            }
          }

          inline_payload {
            name        = "describe_security_groups"
            description = "Devuelve las reglas de ingress y egress vigentes de uno o varios security groups. Usala para verificar si existe la regla que permite el healthcheck desde el security group del balanceador."

            input_schema {
              type = "object"

              property {
                name        = "security_group_ids"
                type        = "string"
                description = "IDs de security group separados por coma, por ejemplo 'sg-111,sg-222'. Si se omite se consultan el SG del balanceador y el de los targets."
                required    = false
              }
            }
          }

          inline_payload {
            name        = "describe_load_balancers"
            description = "Devuelve el estado, DNS, subnets y security groups del Application Load Balancer."

            input_schema {
              type = "object"

              property {
                name        = "load_balancer_arn"
                type        = "string"
                description = "ARN del balanceador. Si se omite se usa el balanceador del incidente."
                required    = false
              }
            }
          }
        }
      }
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "cloudtrail_events" {
  name               = "tool-cloudtrail-events"
  description        = "Busca cambios de configuracion recientes en el historial de CloudTrail."
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tool["tool_cloudtrail_events"].arn

        tool_schema {
          inline_payload {
            name        = "lookup_events"
            description = "Busca en CloudTrail eventos de modificacion de security groups, target groups, balanceadores e instancias dentro de una ventana de tiempo. Devuelve quien hizo el cambio, cuando y con que parametros."

            input_schema {
              type = "object"

              property {
                name        = "minutes"
                type        = "integer"
                description = "Minutos hacia atras desde ahora. Por defecto 60. Maximo 10080."
                required    = false
              }

              property {
                name        = "event_names"
                type        = "string"
                description = "Nombres de evento de CloudTrail separados por coma, por ejemplo 'RevokeSecurityGroupIngress'. Si se omite se busca la lista completa de eventos relevantes para caidas de healthcheck."
                required    = false
              }

              property {
                name        = "resource_name"
                type        = "string"
                description = "ID o nombre exacto de un recurso, por ejemplo 'sg-0a1b2c3d'. Filtrar por recurso es mas preciso que por nombre de evento; usalo cuando ya sepas que recurso sospechas."
                required    = false
              }
            }
          }
        }
      }
    }
  }
}

resource "aws_bedrockagentcore_gateway_target" "cloudwatch_logs" {
  name               = "tool-cloudwatch-logs"
  description        = "Ejecuta consultas de CloudWatch Logs Insights sobre los log groups de la demo."
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tool["tool_cloudwatch_logs"].arn

        tool_schema {
          inline_payload {
            name        = "run_insights_query"
            description = "Ejecuta una consulta de CloudWatch Logs Insights y espera el resultado. El log group por defecto tiene los VPC Flow Logs: buscar registros con action REJECT confirma trafico bloqueado por security group o NACL."

            input_schema {
              type = "object"

              property {
                name        = "query_string"
                type        = "string"
                description = "Consulta en sintaxis de Logs Insights. Si se omite se usa una que lista los rechazos recientes de los flow logs."
                required    = false
              }

              property {
                name        = "log_group_name"
                type        = "string"
                description = "Nombre del log group. Si se omite se usa el de VPC Flow Logs de la VPC del incidente."
                required    = false
              }

              property {
                name        = "minutes"
                type        = "integer"
                description = "Minutos hacia atras desde ahora. Por defecto 60."
                required    = false
              }
            }
          }

          inline_payload {
            name        = "list_log_groups"
            description = "Lista los log groups disponibles. Usala solo si necesitas descubrir que otros logs existen."

            input_schema {
              type = "object"

              property {
                name        = "prefix"
                type        = "string"
                description = "Prefijo del nombre del log group para filtrar."
                required    = false
              }
            }
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Harness: la orquestacion gestionada.
#
# Es el reemplazo directo de aws_bedrockagent_agent. Mismo modelo, mismo system
# prompt (reusado literal del modulo Classic) y las herramientas llegan por el
# gateway en vez de por action groups.
#
# No hace falta preparar el agente ni crear un alias: el harness queda
# invocable en cuanto termina de crearse. Eso elimina el unico `local-exec`
# que tenia el proyecto, y con el la dependencia de AWS CLI.
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_harness" "this" {
  harness_name       = local.harness_name
  execution_role_arn = aws_iam_role.harness.arn

  # Tiene que declararse explicitamente como mapa vacio aunque no usemos
  # variables de entorno. El servicio devuelve {} y el provider no lo normaliza
  # contra un null, asi que dejarlo sin declarar hace fallar la CREACION con
  # "Provider produced inconsistent result after apply: .environment_variables:
  # inconsistent values for sensitive attribute". Solo se manifiesta al crear:
  # en un update in-place no aparece.
  environment_variables = {}

  model {
    bedrock_model_config {
      model_id = var.bedrock_model_id
      # temperature 0: en una demo se quiere el mismo razonamiento en cada ensayo.
      temperature = 0
      max_tokens  = 4096
    }
  }

  system_prompt {
    text = local.agent_instruction
  }

  tool {
    name = "incident_tools"
    type = "agentcore_gateway"

    config {
      agentcore_gateway {
        gateway_arn = aws_bedrockagentcore_gateway.this.gateway_arn

        # El harness firma con SigV4 usando su rol de ejecucion; hace juego
        # con authorizer_type = AWS_IAM del gateway.
        outbound_auth {
          aws_iam = true
        }
      }
    }
  }

  # La investigacion es de una sola pasada: no hace falta memoria entre sesiones
  # y desactivarla evita el costo de un recurso de memoria.
  memory {
    disabled {}
  }

  max_iterations  = var.agent_max_iterations
  timeout_seconds = var.agent_timeout_seconds

  depends_on = [
    aws_bedrockagentcore_gateway_target.resource_state,
    aws_bedrockagentcore_gateway_target.cloudtrail_events,
    aws_bedrockagentcore_gateway_target.cloudwatch_logs,
  ]
}
