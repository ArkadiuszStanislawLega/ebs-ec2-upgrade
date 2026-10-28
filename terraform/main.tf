data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../src/scaler.py"
  output_path = "${path.module}/scaler.zip"
}

resource "aws_cloudwatch_log_group" "scaler_logs" {
  name              = "/aws/lambda/ebs-throughput-scaler-${aws_ebs_volume.poc_oracle_data.id}"
  retention_in_days = 7
}

resource "aws_lambda_function" "ebs_scaler" {
  function_name    = "ebs-throughput-scaler-${aws_ebs_volume.poc_oracle_data.id}"
  role             = aws_iam_role.ebs_scaler_role.arn
  handler          = "scaler.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      VOLUME_ID                  = aws_ebs_volume.poc_oracle_data.id
      BASE_THROUGHPUT            = "125"
      HIGH_THROUGHPUT            = "1000"
      BASE_IOPS                  = "3000"
      HIGH_IOPS                  = "4000"
      SCALE_DOWN_THRESHOLD_MBPS  = "300.0"
      COOLDOWN_HOURS             = "6.0"
      MIN_HOURS_BEFORE_SCALEDOWN = tostring(var.min_hours_before_scaledown)
      LOOKBACK_HOURS             = "1"
    }
  }

  depends_on = [aws_cloudwatch_log_group.scaler_logs]
}

resource "aws_sns_topic" "scale_up_topic" {
  name = "ebs-scale-up-trigger-${aws_ebs_volume.poc_oracle_data.id}"
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
  alarm_name          = "ebs-oracle-throughput-saturation-${aws_ebs_volume.poc_oracle_data.id}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 105
  alarm_description   = "Nasycenie pasma EBS powyzej 105 MB/s przez 2 minuty"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.scale_up_topic.arn]

  metric_query {
    id          = "m_read"
    return_data = false
    metric {
      metric_name = "VolumeReadBytes"
      namespace   = "AWS/EBS"
      period      = 60
      stat        = "Sum"
      dimensions = {
        VolumeId = aws_ebs_volume.poc_oracle_data.id
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
        VolumeId = aws_ebs_volume.poc_oracle_data.id
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
  name                = "ebs-scaledown-check-${aws_ebs_volume.poc_oracle_data.id}"
  description         = "Weryfikacja czy wolumen EBS moze wrocic do 125 MB/s"
  schedule_expression = "rate(15 minutes)"
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
