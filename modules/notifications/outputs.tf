output "sns_topic_arn" {
  description = "ARN del topic de incidentes."
  value       = aws_sns_topic.incidents.arn
}

output "notify_function_arn" {
  description = "ARN de la Lambda notify (la invoca invoke_agent al cerrar el flujo)."
  value       = aws_lambda_function.notify.arn
}

output "notify_function_name" {
  description = "Nombre de la Lambda notify."
  value       = aws_lambda_function.notify.function_name
}

output "notify_slack_function_name" {
  description = "Nombre de la Lambda que reenvia a Slack."
  value       = aws_lambda_function.notify_slack.function_name
}
