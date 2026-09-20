data "aws_caller_identity" "current" {}

# 1. Red: VPC, subnets publicas/privadas en 2 AZs y VPC Flow Logs.
#    Sin NAT Gateway: los targets viven en subnets publicas (ver modules/network).
module "network" {
  source = "./modules/network"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  log_retention_days = var.log_retention_days
}

# 2. Recursos de demo: ALB, target group, 2 EC2 fijas y el SG que se "rompe" en vivo.
module "alb_demo" {
  source = "./modules/alb-demo"

  name_prefix       = local.name_prefix
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  instance_type     = var.instance_type
  allow_healthcheck = var.allow_healthcheck
}

# 3. Notificaciones: se crea antes del agente porque la Lambda invoke_agent
#    necesita el ARN de la Lambda notify para cerrar el flujo.
module "notifications" {
  source = "./modules/notifications"

  name_prefix        = local.name_prefix
  notification_email = var.notification_email
  slack_webhook_url  = var.slack_webhook_url
  log_retention_days = var.log_retention_days
}

# 4. AgentCore (gateway + targets + harness) y las 4 Lambdas (3 tools + invoke_agent).
module "agent" {
  source = "./modules/agent"

  name_prefix                 = local.name_prefix
  bedrock_model_id            = var.bedrock_model_id
  aws_region                  = var.aws_region
  account_id                  = data.aws_caller_identity.current.account_id
  log_retention_days          = var.log_retention_days
  cloudtrail_lookback_minutes = var.cloudtrail_lookback_minutes

  # Contexto del incidente que se le inyecta al agente
  target_group_arn      = module.alb_demo.target_group_arn
  load_balancer_arn     = module.alb_demo.load_balancer_arn
  load_balancer_name    = module.alb_demo.load_balancer_name
  alb_security_group_id = module.alb_demo.alb_security_group_id
  app_security_group_id = module.alb_demo.app_security_group_id
  instance_ids          = module.alb_demo.instance_ids
  flow_log_group_name   = module.network.flow_log_group_name

  notify_function_arn  = module.notifications.notify_function_arn
  notify_function_name = module.notifications.notify_function_name
}

# 5. Monitoreo: alarma UnHealthyHostCount, regla de EventBridge y budget.
module "monitoring" {
  source = "./modules/monitoring"

  name_prefix                = local.name_prefix
  target_group_arn_suffix    = module.alb_demo.target_group_arn_suffix
  load_balancer_arn_suffix   = module.alb_demo.load_balancer_arn_suffix
  invoke_agent_function_arn  = module.agent.invoke_agent_function_arn
  invoke_agent_function_name = module.agent.invoke_agent_function_name

  enable_budget      = var.enable_budget
  budget_limit_usd   = var.budget_limit_usd
  notification_email = var.notification_email
}
