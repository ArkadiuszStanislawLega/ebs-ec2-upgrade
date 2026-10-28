output "instance_id" {
  description = "ID instancji EC2 do polaczenia przez SSM"
  value       = aws_instance.poc_db_host.id
}

output "data_volume_id" {
  description = "ID wolumenu EBS (/oradata)"
  value       = aws_ebs_volume.poc_oracle_data.id
}

output "ssm_connect_command" {
  description = "Komenda do wejscia na serwer z terminala"
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.poc_db_host.id}"
}

output "lambda_logs_command" {
  description = "Komenda do podgladu logow Lambdy na zywo"
  value       = "aws logs tail /aws/lambda/${aws_lambda_function.ebs_scaler.function_name} --region ${var.aws_region} --follow"
}
