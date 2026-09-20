output "vpc_id" {
  description = "ID de la VPC de la demo."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "IDs de las subnets publicas (ALB y targets EC2)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs de las subnets privadas (creadas pero sin uso en esta demo)."
  value       = aws_subnet.private[*].id
}

output "flow_log_group_name" {
  description = "Log group de VPC Flow Logs que consulta el agente."
  value       = aws_cloudwatch_log_group.flow_logs.name
}
