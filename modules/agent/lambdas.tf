# ---------------------------------------------------------------------------
# Las 4 Lambdas del modulo: 3 tools del agente + el orquestador invoke_agent.
#
# Criterio de minimo privilegio: cada Lambda tiene su propio rol, y cada rol
# solo puede escribir en SU log group. Donde la API de AWS soporta permisos a
# nivel de recurso, se acota al recurso concreto de la demo. Las acciones
# Describe*/LookupEvents de EC2, ELBv2 y CloudTrail NO soportan permisos a nivel
# de recurso, asi que ahi el Resource es "*"; queda acotado por la lista de
# acciones, que es de solo lectura.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

locals {
  lambda_runtime = "python3.12"

  # El harness materializa por debajo un AgentCore Runtime gestionado y expone
  # su ARN en `environment_actual`. Se accede con try() porque es un atributo
  # computed anidado: en el primer plan todavia no esta resuelto.
  harness_runtime_arn = try(
    aws_bedrockagentcore_harness.this.environment_actual[0].agentcore_runtime_environment[0].agent_runtime_arn,
    ""
  )

  tool_lambdas = {
    tool_resource_state = {
      timeout = 30
      environment = {
        DEFAULT_TARGET_GROUP_ARN   = var.target_group_arn
        DEFAULT_LOAD_BALANCER_ARN  = var.load_balancer_arn
        DEFAULT_SECURITY_GROUP_IDS = join(",", [var.alb_security_group_id, var.app_security_group_id])
      }
    }
    tool_cloudtrail_events = {
      # LookupEvents es lento: le damos margen para recorrer varios event names.
      timeout = 120
      environment = {
        DEFAULT_LOOKBACK_MINUTES = tostring(var.cloudtrail_lookback_minutes)
      }
    }
    tool_cloudwatch_logs = {
      # Logs Insights hace polling interno hasta 60s.
      timeout = 120
      environment = {
        DEFAULT_LOG_GROUP        = var.flow_log_group_name
        LOG_GROUP_PREFIX         = "/aws/"
        DEFAULT_LOOKBACK_MINUTES = tostring(var.cloudtrail_lookback_minutes)
      }
    }
  }
}

data "archive_file" "tool" {
  for_each = local.tool_lambdas

  type        = "zip"
  source_file = "${path.root}/lambdas/${each.key}/index.py"
  output_path = "${path.module}/.build/${each.key}.zip"
}

resource "aws_iam_role" "tool" {
  for_each = local.tool_lambdas

  name               = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_cloudwatch_log_group" "tool" {
  for_each = local.tool_lambdas

  name              = "/aws/lambda/${var.name_prefix}-${replace(each.key, "_", "-")}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "tool" {
  for_each = local.tool_lambdas

  function_name    = "${var.name_prefix}-${replace(each.key, "_", "-")}"
  role             = aws_iam_role.tool[each.key].arn
  handler          = "index.handler"
  runtime          = local.lambda_runtime
  timeout          = each.value.timeout
  memory_size      = 512
  filename         = data.archive_file.tool[each.key].output_path
  source_code_hash = data.archive_file.tool[each.key].output_base64sha256

  environment {
    variables = each.value.environment
  }

  depends_on = [aws_cloudwatch_log_group.tool]
}

# Permite que AgentCore invoque cada tool, y solo desde ESTE gateway.
resource "aws_lambda_permission" "agentcore_invoke_tool" {
  for_each = local.tool_lambdas

  statement_id   = "AllowAgentCoreGatewayInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.tool[each.key].function_name
  principal      = "bedrock-agentcore.amazonaws.com"
  source_arn     = aws_bedrockagentcore_gateway.this.gateway_arn
  source_account = var.account_id
}

# --- Policies por tool ------------------------------------------------------

data "aws_iam_policy_document" "tool_resource_state" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.tool["tool_resource_state"].arn}:*"]
  }

  statement {
    sid = "ReadOnlyResourceState"
    actions = [
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeLoadBalancers",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
    ]
    # Estas acciones no admiten permisos a nivel de recurso.
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "tool_cloudtrail_events" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.tool["tool_cloudtrail_events"].arn}:*"]
  }

  statement {
    sid       = "ReadCloudTrailHistory"
    actions   = ["cloudtrail:LookupEvents"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "tool_cloudwatch_logs" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.tool["tool_cloudwatch_logs"].arn}:*"]
  }

  statement {
    sid     = "StartInsightsQueries"
    actions = ["logs:StartQuery"]
    # StartQuery si admite recurso: acotado a los log groups de la demo.
    resources = [
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:${var.flow_log_group_name}:*",
      "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/lambda/${var.name_prefix}-*:*",
    ]
  }

  statement {
    sid = "ReadQueryResults"
    actions = [
      "logs:GetQueryResults",
      "logs:StopQuery",
      "logs:DescribeLogGroups",
    ]
    # Estas tres no admiten permisos a nivel de recurso.
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "tool" {
  for_each = local.tool_lambdas

  name = each.key
  role = aws_iam_role.tool[each.key].id
  policy = lookup(
    {
      tool_resource_state    = data.aws_iam_policy_document.tool_resource_state.json
      tool_cloudtrail_events = data.aws_iam_policy_document.tool_cloudtrail_events.json
      tool_cloudwatch_logs   = data.aws_iam_policy_document.tool_cloudwatch_logs.json
    },
    each.key,
    null
  )
}

# ---------------------------------------------------------------------------
# invoke_agent: orquestador disparado por EventBridge.
# ---------------------------------------------------------------------------

data "archive_file" "invoke_agent" {
  type        = "zip"
  source_file = "${path.root}/lambdas/invoke_agent/index.py"
  output_path = "${path.module}/.build/invoke_agent.zip"
}

resource "aws_iam_role" "invoke_agent" {
  name               = "${var.name_prefix}-invoke-agent"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_cloudwatch_log_group" "invoke_agent" {
  name              = "/aws/lambda/${var.name_prefix}-invoke-agent"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "invoke_agent" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.invoke_agent.arn}:*"]
  }

  statement {
    sid = "InvokeThisHarness"
    # Llamar a la operacion InvokeHarness exige DOS acciones IAM, no una. El
    # servicio las evalua en cascada sobre el mismo ARN de harness: primero
    # InvokeAgentRuntime y despues InvokeHarness. Concediendo solo una, el
    # AccessDenied nombra la otra.
    #
    # Verificado empiricamente contra la cuenta: con solo InvokeAgentRuntime el
    # error pedia InvokeHarness, y viceversa. No es deducible del modelo de
    # servicio de botocore ni de un unico mensaje de error.
    actions = [
      "bedrock-agentcore:InvokeAgentRuntime",
      "bedrock-agentcore:InvokeHarness",
    ]
    resources = [
      aws_bedrockagentcore_harness.this.arn,
      "${aws_bedrockagentcore_harness.this.arn}/*",
    ]
  }

  statement {
    sid       = "CloseTheLoopWithNotify"
    actions   = ["lambda:InvokeFunction"]
    resources = [var.notify_function_arn]
  }
}

resource "aws_iam_role_policy" "invoke_agent" {
  name   = "invoke-agent"
  role   = aws_iam_role.invoke_agent.id
  policy = data.aws_iam_policy_document.invoke_agent.json
}

resource "aws_lambda_function" "invoke_agent" {
  function_name = "${var.name_prefix}-invoke-agent"
  role          = aws_iam_role.invoke_agent.arn
  handler       = "index.handler"
  runtime       = local.lambda_runtime
  # El agente encadena varias tools; 5 minutos es holgado para la demo.
  timeout          = 300
  memory_size      = 512
  filename         = data.archive_file.invoke_agent.output_path
  source_code_hash = data.archive_file.invoke_agent.output_base64sha256

  environment {
    variables = {
      HARNESS_ARN                 = aws_bedrockagentcore_harness.this.arn
      HARNESS_ID                  = aws_bedrockagentcore_harness.this.harness_id
      NOTIFY_FUNCTION_NAME        = var.notify_function_name
      TARGET_GROUP_ARN            = var.target_group_arn
      LOAD_BALANCER_ARN           = var.load_balancer_arn
      LOAD_BALANCER_NAME          = var.load_balancer_name
      INSTANCE_IDS                = join(",", var.instance_ids)
      ALB_SECURITY_GROUP_ID       = var.alb_security_group_id
      APP_SECURITY_GROUP_ID       = var.app_security_group_id
      FLOW_LOG_GROUP_NAME         = var.flow_log_group_name
      CLOUDTRAIL_LOOKBACK_MINUTES = tostring(var.cloudtrail_lookback_minutes)
    }
  }

  depends_on = [aws_cloudwatch_log_group.invoke_agent]
}
