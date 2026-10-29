# terraform/main.tf
locals {
  alarm_name = "ebs-oracle-throughput-saturation-${var.volume_id}"
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/scaler.py"
  output_path = "${path.module}/scaler.zip"
}

resource "aws_cloudwatch_log_group" "scaler_logs" {
  name              = "/aws/lambda/ebs-throughput-scaler-${var.volume_id}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "ebs_scaler" {
  function_name    = "ebs-throughput-scaler-${var.volume_id}"
  description      = "Automated EBS gp3 throughput/IOPS scaler for Oracle volume ${var.volume_id}"
  role             = aws_iam_role.ebs_scaler_role.arn
  handler          = "scaler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  memory_size      = 256
  tags             = var.tags

  environment {
    variables = {
      VOLUME_ID                    = var.volume_id
      ALARM_NAME                   = local.alarm_name
      BASE_THROUGHPUT              = tostring(var.base_throughput)
      HIGH_THROUGHPUT              = tostring(var.high_throughput)
      BASE_IOPS                    = tostring(var.base_iops)
      HIGH_IOPS                    = tostring(var.high_iops)
      SCALE_DOWN_THRESHOLD_MBPS    = tostring(var.scale_down_threshold_mbps)
      MIN_MINUTES_BEFORE_SCALEDOWN = tostring(var.min_minutes_before_scaledown)
      LOOKBACK_MINUTES             = tostring(var.lookback_minutes)
    }
  }

  depends_on = [aws_cloudwatch_log_group.scaler_logs]
}

resource "aws_sns_topic" "scale_up_topic" {
  name = "ebs-scale-up-trigger-${var.volume_id}"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.scale_up_topic.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.ebs_scaler.arn
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ebs_scaler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.scale_up_topic.arn
}

resource "aws_cloudwatch_metric_alarm" "ebs_throughput_high" {
  alarm_name          = local.alarm_name
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.scale_up_threshold_mbps
  alarm_description   = "EBS throughput saturation above ${var.scale_up_threshold_mbps} MB/s on volume ${var.volume_id}"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.scale_up_topic.arn]
  tags                = var.tags

  metric_query {
    id          = "m_read"
    return_data = false
    metric {
      metric_name = "VolumeReadBytes"
      namespace   = "AWS/EBS"
      period      = 60
      stat        = "Sum"
      dimensions = {
        VolumeId = var.volume_id
      }
    }
  }

  metric_query {
    id          = "m_write"
    return_data = false
    metric {
      metric_name = "VolumeWriteBytes"
      namespace   = "AWS/EBS"
      period      = 60
      stat        = "Sum"
      dimensions = {
        VolumeId = var.volume_id
      }
    }
  }

  metric_query {
    id          = "e_throughput_mbps"
    expression  = "(m_read + m_write) / PERIOD(m_read) / 1048576"
    label       = "TotalThroughputMBps"
    return_data = true
  }
}

resource "aws_cloudwatch_event_rule" "periodic_scaledown_check" {
  name                = "ebs-scaledown-check-${var.volume_id}"
  description         = "Periodic scale-down evaluation for volume ${var.volume_id}"
  schedule_expression = var.scaledown_check_schedule
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "invoke_lambda_scaledown" {
  rule      = aws_cloudwatch_event_rule.periodic_scaledown_check.name
  target_id = "InvokeEbsScalerDown"
  arn       = aws_lambda_function.ebs_scaler.arn
  input     = jsonencode({ action = "scale_down" })
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ebs_scaler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.periodic_scaledown_check.arn
}
