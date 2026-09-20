variable "name_prefix" {
  type        = string
  description = "Prefijo de nombres."
}

variable "vpc_id" {
  type        = string
  description = "VPC donde se despliegan ALB y targets."
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Subnets publicas para el ALB y las instancias."
}

variable "instance_type" {
  type        = string
  description = "Tipo de instancia de los targets."
  default     = "t3.micro"
}

variable "allow_healthcheck" {
  type        = bool
  description = "Si es true, existe la regla de ingress TCP/80 desde el SG del ALB hacia el SG de la app. Ponerlo en false es lo que rompe el ambiente durante la demo."
  default     = true
}

variable "app_port" {
  type        = number
  description = "Puerto donde escucha nginx en los targets."
  default     = 80
}

variable "ingress_cidr" {
  type        = string
  description = "CIDR que puede llegar al ALB por HTTP."
  default     = "0.0.0.0/0"
}
