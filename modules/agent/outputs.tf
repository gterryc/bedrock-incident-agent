output "harness_id" {
  description = "ID del harness de AgentCore (la orquestacion del agente)."
  value       = aws_bedrockagentcore_harness.this.harness_id
}

output "harness_arn" {
  description = "ARN del harness de AgentCore."
  value       = aws_bedrockagentcore_harness.this.arn
}

output "agent_runtime_arn" {
  description = "ARN del AgentCore Runtime gestionado que materializa el harness; es lo que invoca la Lambda invoke_agent."
  value       = local.harness_runtime_arn
}

output "gateway_id" {
  description = "ID del Gateway MCP que expone las herramientas."
  value       = aws_bedrockagentcore_gateway.this.gateway_id
}

output "gateway_arn" {
  description = "ARN del Gateway MCP."
  value       = aws_bedrockagentcore_gateway.this.gateway_arn
}

output "gateway_url" {
  description = "Endpoint MCP del gateway. Sirve para probar las herramientas con un cliente MCP fuera del agente."
  value       = aws_bedrockagentcore_gateway.this.gateway_url
}

output "invoke_agent_function_arn" {
  description = "ARN de la Lambda invoke_agent (target de EventBridge)."
  value       = aws_lambda_function.invoke_agent.arn
}

output "invoke_agent_function_name" {
  description = "Nombre de la Lambda invoke_agent."
  value       = aws_lambda_function.invoke_agent.function_name
}

output "invoke_agent_log_group_name" {
  description = "Log group con el trace de razonamiento del agente."
  value       = aws_cloudwatch_log_group.invoke_agent.name
}

output "tool_function_names" {
  description = "Nombres de las Lambdas que respaldan los targets del gateway."
  value       = { for k, v in aws_lambda_function.tool : k => v.function_name }
}
