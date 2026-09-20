# Backend local por defecto para que `terraform init` funcione sin dependencias previas.
# Si preferis estado remoto, descomenta el bloque y completa bucket/key.
#
# terraform {
#   backend "s3" {
#     bucket = "*****"
#     key    = "bedrock-incident-agent/terraform.tfstate"
#     region = "us-east-1"
#   }
# }
