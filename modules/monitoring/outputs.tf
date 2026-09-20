output "alarm_name" {
  description = "Nombre de la alarma que dispara el flujo."
  value       = aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name
}

output "alarm_arn" {
  description = "ARN de la alarma."
  value       = aws_cloudwatch_metric_alarm.unhealthy_hosts.arn
}

output "event_rule_name" {
  description = "Nombre de la regla de EventBridge."
  value       = aws_cloudwatch_event_rule.alarm_to_agent.name
}

output "budget_name" {
  description = "Nombre del budget mensual, si esta habilitado."
  value       = var.enable_budget ? aws_budgets_budget.monthly[0].name : null
}
