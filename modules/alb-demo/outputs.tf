output "load_balancer_arn" {
  description = "ARN del ALB."
  value       = aws_lb.this.arn
}

output "load_balancer_name" {
  description = "Nombre del ALB."
  value       = aws_lb.this.name
}

output "load_balancer_dns_name" {
  description = "DNS publico del ALB."
  value       = aws_lb.this.dns_name
}

output "load_balancer_arn_suffix" {
  description = "Sufijo del ARN del ALB, usado como dimension de la metrica de CloudWatch."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arn" {
  description = "ARN del target group."
  value       = aws_lb_target_group.this.arn
}

output "target_group_arn_suffix" {
  description = "Sufijo del ARN del target group, usado como dimension de la metrica."
  value       = aws_lb_target_group.this.arn_suffix
}

output "alb_security_group_id" {
  description = "SG del ALB (origen del healthcheck)."
  value       = aws_security_group.alb.id
}

output "app_security_group_id" {
  description = "SG de los targets (el que se modifica para romper la demo)."
  value       = aws_security_group.app.id
}

output "instance_ids" {
  description = "IDs de las 2 instancias target."
  value       = aws_instance.app[*].id
}
