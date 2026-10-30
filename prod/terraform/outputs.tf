output "enrolled_volumes" {
  description = "Map of enrolled EBS volume IDs to their ARNs and detected initial IOPS"
  value = {
    for vol_id, vol in data.aws_ebs_volume.managed_volumes : vol_id => {
      arn           = vol.arn
      detected_iops = vol.iops
      size_gb       = vol.size
    }
  }
}

output "scaler_lambda_name" {
  description = "Name of the centralized EBS scaler Lambda function"
  value       = aws_lambda_function.ebs_scaler.function_name
}

output "cloudwatch_alarm_names" {
  description = "Map of volume IDs to their CloudWatch alarm names"
  value       = { for k, v in aws_cloudwatch_metric_alarm.ebs_throughput_high : k => v.alarm_name }
}

output "eventbridge_rule_name" {
  description = "Name of the shared EventBridge rule triggering periodic scale-down"
  value       = aws_cloudwatch_event_rule.periodic_scaledown_check.name
}
