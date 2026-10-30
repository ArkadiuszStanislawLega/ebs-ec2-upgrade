locals {
  volumes_runtime_config = {
    for vol_id, cfg in var.volumes : vol_id => {
      alarm_name                   = "${var.name_prefix}-saturation-${vol_id}"
      base_throughput              = cfg.base_throughput
      high_throughput              = cfg.high_throughput
      base_iops                    = cfg.base_iops
      high_iops                    = cfg.high_iops
      scale_down_threshold_mbps    = cfg.scale_down_threshold_mbps
      min_minutes_before_scaledown = cfg.min_minutes_before_scaledown
      lookback_minutes             = cfg.lookback_minutes
    }
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/scaler.py"
  output_path = "${path.module}/scaler.zip"
}

resource "aws_cloudwatch_log_group" "scaler_logs" {
  name              = "/aws/lambda/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "ebs_scaler" {
  function_name    = var.name_prefix
  description      = "Centralized multi-volume EBS gp3 throughput/IOPS auto-scaler"
  role             = aws_iam_role.ebs_scaler_role.arn
  handler          = "scaler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 60
  memory_size      = 256
  tags             = var.tags

  environment {
    variables = {
      VOLUMES_CONFIG_JSON = jsonencode(local.volumes_runtime_config)
    }
  }

  depends_on = [aws_cloudwatch_log_group.scaler_logs]
}

# --- SHARED SNS TOPIC FOR SCALE-UP EVENTS ---
resource "aws_sns_topic" "scale_up_topic" {
  name = "${var.name_prefix}-scale-up-topic"
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

# --- PER-VOLUME CLOUDWATCH METRIC MATH ALARMS ---
resource "aws_cloudwatch_metric_alarm" "ebs_throughput_high" {
  for_each = var.volumes

  alarm_name          = local.volumes_runtime_config[each.key].alarm_name
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = each.value.scale_up_threshold_mbps
  alarm_description   = "EBS throughput saturation above ${each.value.scale_up_threshold_mbps} MB/s on volume ${each.key}"
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
        VolumeId = each.key
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
        VolumeId = each.key
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

# --- SHARED EVENTBRIDGE RULE FOR PERIODIC SCALE-DOWN ---
resource "aws_cloudwatch_event_rule" "periodic_scaledown_check" {
  name                = "${var.name_prefix}-scaledown-check"
  description         = "Periodic batch scale-down evaluation for all enrolled EBS volumes"
  schedule_expression = var.scaledown_check_schedule
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "invoke_lambda_scaledown" {
  rule      = aws_cloudwatch_event_rule.periodic_scaledown_check.name
  target_id = "InvokeEbsScalerDownBatch"
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
