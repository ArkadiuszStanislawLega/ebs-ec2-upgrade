aws_region                   = "eu-central-1"
volume_id                    = "vol-0663e1160ec359efa"
base_throughput              = 125
high_throughput              = 1000
base_iops                    = 3000
high_iops                    = 4000
scale_up_threshold_mbps      = 105
scale_down_threshold_mbps    = 85
min_minutes_before_scaledown = 60
lookback_minutes             = 60
scaledown_check_schedule     = "rate(30 minutes)"
log_retention_days           = 90

tags = {
  Project     = "Oracle-EBS-AutoThroughput"
  ManagedBy   = "Terraform"
  Environment = "production"
}
