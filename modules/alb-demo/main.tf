# AMI Amazon Linux 2023 vigente, resuelta desde el parametro publico de SSM.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "SG del Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP publico hacia el ALB"
  cidr_ipv4         = var.ingress_cidr
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Salida libre del ALB hacia los targets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "SG de los targets EC2"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-app-sg"
  }
}

# *** El interruptor de la demo ***
# Esta es la unica regla que permite que el healthcheck del ALB llegue a nginx.
# `terraform apply -var="allow_healthcheck=false"` la destruye y el target group
# pasa a unhealthy en ~20s (interval 10s x unhealthy_threshold 2).
resource "aws_vpc_security_group_ingress_rule" "app_healthcheck" {
  count = var.allow_healthcheck ? 1 : 0

  security_group_id            = aws_security_group.app.id
  description                  = "Healthcheck y trafico HTTP desde el SG del ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"

  tags = {
    Name = "${var.name_prefix}-allow-healthcheck"
  }
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Salida a internet para instalar nginx y hablar con SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Instancias: exactamente 2, sin Auto Scaling Group (decision del proyecto).
# Instance profile con SSM para poder entrar por Session Manager si hace falta
# depurar en vivo, sin abrir SSH ni crear key pairs.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance"
  role = aws_iam_role.instance.name
}

resource "aws_instance" "app" {
  count = 2

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_ids[count.index % length(var.public_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  user_data              = file("${path.module}/user_data.sh")

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.name_prefix}-target-${count.index + 1}"
    Role = "demo-target"
  }
}

# ---------------------------------------------------------------------------
# ALB + Target Group
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # La demo se destruye seguido; sin proteccion de borrado.
  enable_deletion_protection = false

  tags = {
    Name = "${var.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "this" {
  name        = "${var.name_prefix}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  # interval 10s x unhealthy_threshold 2 => unhealthy en ~20s,
  # a tiempo para que la alarma de 1 periodo de 60s dispare en la charla.
  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 10

  tags = {
    Name = "${var.name_prefix}-tg"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  count = length(aws_instance.app)

  target_group_arn = aws_lb_target_group.this.arn
  target_id        = aws_instance.app[count.index].id
  port             = var.app_port
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
