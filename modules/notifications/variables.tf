variable "name_prefix" {
  type        = string
  description = "Prefijo de nombres."
}

variable "notification_email" {
  type        = string
  description = "Email suscrito al topic SNS."
}

variable "slack_webhook_url" {
  type        = string
  description = "Incoming Webhook de Slack. Vacio desactiva el envio (la Lambda solo loguea)."
  default     = ""
  sensitive   = true
}

variable "log_retention_days" {
  type        = number
  description = "Retencion de los log groups de las Lambdas."
  default     = 1
}
