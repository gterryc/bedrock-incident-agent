variable "name_prefix" {
  type        = string
  description = "Prefijo de nombres."
}

variable "target_group_arn_suffix" {
  type        = string
  description = "Sufijo del ARN del target group (dimension de la metrica)."
}

variable "load_balancer_arn_suffix" {
  type        = string
  description = "Sufijo del ARN del ALB (dimension de la metrica)."
}

variable "invoke_agent_function_arn" {
  type        = string
  description = "ARN de la Lambda que EventBridge invoca al dispararse la alarma."
}

variable "invoke_agent_function_name" {
  type        = string
  description = "Nombre de la Lambda invoke_agent."
}

variable "enable_budget" {
  type        = bool
  description = "Crea el AWS Budget mensual."
  default     = true
}

variable "budget_limit_usd" {
  type        = string
  description = "Limite mensual del budget en USD."
  default     = "20"
}

variable "notification_email" {
  type        = string
  description = "Email que recibe las alertas del budget."
}
