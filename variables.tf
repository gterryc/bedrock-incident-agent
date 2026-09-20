variable "aws_region" {
  type        = string
  description = "AWS region donde se despliega la demo. Bedrock AgentCore debe estar disponible aqui."
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Prefijo para nombrar todos los recursos de la demo."
  default     = "bedrock-incident-agent"

  # Los tres recursos de AgentCore validan sus nombres con reglas distintas y
  # incompatibles entre si (ver el comentario en modules/agent/main.tf). Este
  # formato es el unico que satisface las tres a la vez tras las conversiones
  # que hace el modulo; se valida aqui para fallar con un mensaje claro en vez
  # de con un regex del provider a mitad del apply.
  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.project_name))
    error_message = "project_name debe empezar con letra minuscula y usar solo minusculas, digitos y guiones medios simples (sin guiones bajos, sin guiones dobles ni al final)."
  }

  validation {
    condition     = length(var.project_name) <= 34
    error_message = "project_name no puede superar 34 caracteres: el harness admite 40 y el gateway le agrega el sufijo '-tools'."
  }
}

variable "notification_email" {
  type        = string
  description = "Email que recibe la notificacion final del agente via SNS. Requiere confirmar la suscripcion desde el correo."
}

variable "slack_webhook_url" {
  type        = string
  description = "Incoming Webhook de Slack. Se deja vacio por defecto: si esta vacio, la Lambda notify_slack loguea el mensaje y no intenta enviarlo."
  default     = ""
  sensitive   = true
}

variable "allow_healthcheck" {
  type        = bool
  description = "Interruptor de la demo. En true el SG del target permite el healthcheck desde el SG del ALB. En false esa regla de ingress se elimina y el target group se pone unhealthy."
  default     = true
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR de la VPC de la demo."
  default     = "10.42.0.0/16"
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia de los targets EC2. t3.micro es suficiente para servir un healthcheck."
  default     = "t3.micro"
}

variable "bedrock_model_id" {
  type        = string
  description = "Modelo base del agente de AgentCore. Por defecto el inference profile cross-region de Claude Sonnet 4.5. Ver la seccion de troubleshooting del README si tu cuenta no tiene acceso a este modelo."
  default     = "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "cloudtrail_lookback_minutes" {
  type        = number
  description = "Ventana por defecto (en minutos, hacia atras desde el disparo de la alarma) que el agente usa para buscar cambios en CloudTrail."
  default     = 60
}

variable "log_retention_days" {
  type        = number
  description = "Retencion de todos los log groups de la demo. Se deja baja a proposito para minimizar costo."
  default     = 1
}

variable "enable_budget" {
  type        = bool
  description = "Crea un AWS Budget mensual con alerta por email."
  default     = true
}

variable "budget_limit_usd" {
  type        = string
  description = "Limite mensual del budget en USD."
  default     = "20"
}
