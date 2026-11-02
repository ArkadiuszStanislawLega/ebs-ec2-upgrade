aws_region                   = "eu-central-1"
name_prefix                  = "oracle-ebs-scaler"
scaledown_check_schedule     = "rate(30 minutes)"
log_retention_days           = 90

volumes = {
  "vol-0633e29e75e756ea6" = {}
}

tags = {
  Project     = "Oracle-EBS-AutoThroughput"
  ManagedBy   = "Terraform"
  Environment = "production"
}
