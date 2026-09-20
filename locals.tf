locals {
  name_prefix = var.project_name

  common_tags = {
    Owner       = "George Terry"
    Environment = "Demo"
    Project     = "bedrock-incident-agent"
    Empresa     = "AWS Community Day"
    Deployment  = "Terraform"
    Domain      = "GenAI/Observability"
  }
}
