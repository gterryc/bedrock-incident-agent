variable "name_prefix" {
  type        = string
  description = "Prefijo de nombres."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR de la VPC."
}

variable "log_retention_days" {
  type        = number
  description = "Retencion del log group de VPC Flow Logs."
}
