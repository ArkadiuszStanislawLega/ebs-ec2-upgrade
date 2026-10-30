variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "Target AWS region where the EBS volumes and control plane reside"
}

variable "name_prefix" {
  type        = string
  default     = "oracle-ebs-scaler"
  description = "Prefix used for naming shared control-plane resources (Lambda, IAM Role, SNS, EventBridge)"
}

variable "volumes" {
  type = map(object({
    base_throughput              = optional(number, 125)
    high_throughput              = optional(number, 1000)
    base_iops                    = optional(number, 3000)
    high_iops                    = optional(number, 4000)
    scale_up_threshold_mbps      = optional(number, 105)
    scale_down_threshold_mbps    = optional(number, 85)
    min_minutes_before_scaledown = optional(number, 60)
    lookback_minutes             = optional(number, 60)
  }))
  description = "Map of EBS volume IDs to their scaling parameters. Omit attributes to use production defaults."

  validation {
    condition     = length(var.volumes) > 0 && alltrue([for k in keys(var.volumes) : can(regex("^vol-[a-f0-9]{17}$", k))])
    error_message = "At least one volume must be defined, and all map keys must be valid EBS volume IDs (vol-xxxxxxxxxxxxxxxxx)."
  }

  validation {
    condition     = alltrue([for v in values(var.volumes) : v.scale_down_threshold_mbps < v.scale_up_threshold_mbps])
    error_message = "For every volume, scale_down_threshold_mbps must be strictly lower than scale_up_threshold_mbps."
  }

  validation {
    condition     = alltrue([for v in values(var.volumes) : v.high_iops >= (v.high_throughput * 4)])
    error_message = "EBS gp3 requires at least 1 IOPS per 0.25 MB/s of throughput (e.g., 4000 IOPS for 1000 MB/s)."
  }
}

variable "scaledown_check_schedule" {
  type        = string
  default     = "rate(30 minutes)"
  description = "EventBridge schedule expression for periodic batch scale-down evaluation"
}

variable "log_retention_days" {
  type        = number
  default     = 90
  description = "CloudWatch Log Group retention period in days"
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Resource tags applied to all control-plane components"
}
