variable "name_prefix" {
  type        = string
  description = "Prefijo de nombres."
}

variable "aws_region" {
  type        = string
  description = "Region donde vive el agente."
}

variable "account_id" {
  type        = string
  description = "Account ID, usado para construir ARNs en las policies."
}

variable "bedrock_model_id" {
  type        = string
  description = "Model ID o inference profile ID del modelo base del agente."
}

variable "log_retention_days" {
  type        = number
  description = "Retencion de los log groups de las Lambdas."
  default     = 1
}

variable "cloudtrail_lookback_minutes" {
  type        = number
  description = "Ventana por defecto de busqueda en CloudTrail."
  default     = 60
}

variable "target_group_arn" {
  type        = string
  description = "Target group del incidente; valor por defecto de las tools."
}

variable "load_balancer_arn" {
  type        = string
  description = "ALB del incidente; valor por defecto de las tools."
}

variable "load_balancer_name" {
  type        = string
  description = "Nombre del ALB, usado en la policy de CloudTrail y en el prompt."
}

variable "alb_security_group_id" {
  type        = string
  description = "SG del ALB (origen del healthcheck)."
}

variable "app_security_group_id" {
  type        = string
  description = "SG de los targets (el recurso modificado)."
}

variable "instance_ids" {
  type        = list(string)
  description = "IDs de las instancias target."
  default     = []
}

variable "flow_log_group_name" {
  type        = string
  description = "Log group de VPC Flow Logs que consulta tool_cloudwatch_logs por defecto."
}

variable "notify_function_arn" {
  type        = string
  description = "ARN de la Lambda notify que cierra el flujo."
}

variable "notify_function_name" {
  type        = string
  description = "Nombre de la Lambda notify."
}

variable "agent_timeout_seconds" {
  type        = number
  description = "Tope de duracion de una investigacion del harness. Reemplaza al idle_session_ttl_in_seconds de Bedrock Agents Classic, que AgentCore no expone."
  default     = 240
}

variable "agent_max_iterations" {
  type        = number
  description = "Tope de vueltas del bucle agentico. Medido contra la cuenta real: con 12 el agente agotaba el tope investigando flow logs y terminaba con max_iterations_exceeded, sin llegar a conclusion. 25 le alcanza de sobra y sigue acotando el costo si algo se cicla."
  default     = 25
}
