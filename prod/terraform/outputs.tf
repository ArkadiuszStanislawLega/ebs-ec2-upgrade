output "monitored_volume_arn" {
  description = "ARN of the monitored production EBS volume"
  value       = data.aws_ebs_volume.target_oracle_vol.arn
}

output "detected_initial_iops" {
  description = "IOPS value detected on the volume during Terraform read"
  value       = data.aws_ebs_volume.target_oracle_vol.iops
}

output "scaler_lambda_name" {
  description = "Name of the deployed EBS scaler Lambda function"
  value       = aws_lambda_function.ebs_scaler.function_name
}

output "cloudwatch_alarm_name" {
  description = "Name of the CloudWatch Metric Math alarm triggering scale-up"
  value       = aws_cloudwatch_metric_alarm.ebs_throughput_high.alarm_name
}

output "eventbridge_rule_name" {
  description = "Name of the EventBridge rule triggering periodic scale-down checks"
  value       = aws_cloudwatch_event_rule.periodic_scaledown_check.name
}
