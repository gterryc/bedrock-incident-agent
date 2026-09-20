# ---------------------------------------------------------------------------
# SNS con dos destinos: email directo y Lambda que reenvia a Slack.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "incidents" {
  name = "${var.name_prefix}-incidents"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.incidents.arn
  protocol  = "email"
  endpoint  = var.notification_email
  # OJO: hay que confirmar la suscripcion desde el correo antes de la demo.
}

# ---------------------------------------------------------------------------
# Lambda notify: publica en el topic el diagnostico final del agente.
# ---------------------------------------------------------------------------

data "archive_file" "notify" {
  type        = "zip"
  source_file = "${path.root}/lambdas/notify/index.py"
  output_path = "${path.module}/.build/notify.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "notify" {
  name               = "${var.name_prefix}-notify"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${var.name_prefix}-notify"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "notify" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.notify.arn}:*"]
  }

  statement {
    sid       = "PublishIncidentTopic"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.incidents.arn]
  }
}

resource "aws_iam_role_policy" "notify" {
  name   = "notify"
  role   = aws_iam_role.notify.id
  policy = data.aws_iam_policy_document.notify.json
}

resource "aws_lambda_function" "notify" {
  function_name    = "${var.name_prefix}-notify"
  role             = aws_iam_role.notify.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.notify.output_path
  source_code_hash = data.archive_file.notify.output_base64sha256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.incidents.arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.notify]
}

# ---------------------------------------------------------------------------
# Lambda notify_slack: suscrita al topic, reenvia al webhook.
# ---------------------------------------------------------------------------

data "archive_file" "notify_slack" {
  type        = "zip"
  source_file = "${path.root}/lambdas/notify_slack/index.py"
  output_path = "${path.module}/.build/notify_slack.zip"
}

resource "aws_iam_role" "notify_slack" {
  name               = "${var.name_prefix}-notify-slack"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_cloudwatch_log_group" "notify_slack" {
  name              = "/aws/lambda/${var.name_prefix}-notify-slack"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "notify_slack" {
  statement {
    sid       = "WriteOwnLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.notify_slack.arn}:*"]
  }
}

resource "aws_iam_role_policy" "notify_slack" {
  name   = "notify-slack"
  role   = aws_iam_role.notify_slack.id
  policy = data.aws_iam_policy_document.notify_slack.json
}

resource "aws_lambda_function" "notify_slack" {
  function_name    = "${var.name_prefix}-notify-slack"
  role             = aws_iam_role.notify_slack.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.notify_slack.output_path
  source_code_hash = data.archive_file.notify_slack.output_base64sha256

  environment {
    variables = {
      # Valor sensible: viaja como variable de entorno cifrada en reposo por Lambda.
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  depends_on = [aws_cloudwatch_log_group.notify_slack]
}

resource "aws_lambda_permission" "sns_invoke_slack" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.notify_slack.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.incidents.arn
}

resource "aws_sns_topic_subscription" "slack" {
  topic_arn = aws_sns_topic.incidents.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.notify_slack.arn

  depends_on = [aws_lambda_permission.sns_invoke_slack]
}
