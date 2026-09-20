output "alb_dns_name" {
  description = "URL del ALB. Sirve para comprobar a mano que la app responde (y que deja de responder al romper el SG)."
  value       = "http://${module.alb_demo.load_balancer_dns_name}/health"
}

output "target_group_arn" {
  description = "ARN del target group vigilado por la alarma."
  value       = module.alb_demo.target_group_arn
}

output "app_security_group_id" {
  description = "SG de los targets: es el recurso que se modifica para provocar el incidente."
  value       = module.alb_demo.app_security_group_id
}

output "alarm_name" {
  description = "Nombre de la alarma de CloudWatch que dispara el flujo."
  value       = module.monitoring.alarm_name
}

output "agentcore_harness_id" {
  description = "ID del harness de AgentCore."
  value       = module.agent.harness_id
}

output "agentcore_gateway_id" {
  description = "ID del Gateway MCP que expone las 3 herramientas."
  value       = module.agent.gateway_id
}

output "agentcore_gateway_url" {
  description = "Endpoint MCP del gateway."
  value       = module.agent.gateway_url
}

output "invoke_agent_log_group" {
  description = "Log group donde se imprime el trace de razonamiento del agente."
  value       = module.agent.invoke_agent_log_group_name
}

output "sns_topic_arn" {
  description = "Topic SNS con las notificaciones finales."
  value       = module.notifications.sns_topic_arn
}

output "tail_trace_command" {
  description = "Comando listo para seguir el trace del agente en vivo durante la demo."
  value       = "aws logs tail ${module.agent.invoke_agent_log_group_name} --follow --since 5m --region ${var.aws_region}"
}

output "invoke_agent_function_name" {
  description = "Nombre de la Lambda invoke_agent, util para invocarla a mano al ensayar."
  value       = module.agent.invoke_agent_function_name
}
