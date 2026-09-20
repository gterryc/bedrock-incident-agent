# ---------------------------------------------------------------------------
# Alarma: UnHealthyHostCount > 0.
#
# period=60 y evaluation_periods=1 -> dispara en aproximadamente 1 minuto desde
# que el target queda unhealthy. Es agresivo para produccion real, pero es lo
# que hace viable mostrar el flujo completo en vivo.
#
# treat_missing_data = notBreaching evita que la alarma dispare sola durante el
# despliegue inicial, cuando todavia no hay datos de la metrica.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name_prefix}-unhealthy-hosts"
  alarm_description   = "Hay targets unhealthy en el target group de la demo. Dispara la investigacion automatica del Bedrock Agent."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = var.target_group_arn_suffix
    LoadBalancer = var.load_balancer_arn_suffix
  }

  tags = {
    Name = "${var.name_prefix}-unhealthy-hosts"
  }
}

# ---------------------------------------------------------------------------
# EventBridge: alarma en ALARM -> Lambda invoke_agent.
#
# Se escucha el evento "CloudWatch Alarm State Change" en vez de conectar la
# alarma directo a SNS: asi el trigger lleva el contexto completo (metrica,
# dimensiones, motivo) que la Lambda le pasa al agente.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "alarm_to_agent" {
  name        = "${var.name_prefix}-alarm-to-agent"
  description = "Invoca al Bedrock Agent cuando la alarma de targets unhealthy pasa a ALARM."

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name]
      state = {
        value = ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "invoke_agent" {
  rule      = aws_cloudwatch_event_rule.alarm_to_agent.name
  target_id = "invoke-agent"
  arn       = var.invoke_agent_function_arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = var.invoke_agent_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_to_agent.arn
}

# ---------------------------------------------------------------------------
# AWS Budget: alerta de gasto mensual.
#
# Se incluye porque es un solo recurso y no agrega dependencias al deploy.
# Notifica al 80% del gasto real y al 100% del gasto proyectado.
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  count = var.enable_budget ? 1 : 0

  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.notification_email]
  }
}
