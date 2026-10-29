variable "volume_id" {
  type        = string
  description = "Target production EBS volume ID (gp3) storing Oracle database files"

  validation {
    condition     = can(regex("^vol-[a-f0-9]{17}$", var.volume_id))
    error_message = "Must be a valid AWS EBS volume ID (format: vol-xxxxxxxxxxxxxxxxx)."
  }
}

variable "base_throughput" {
  type        = number
  default     = 125
  description = "Baseline throughput (MB/s) restored after peak workload finishes"

  validation {
    condition     = var.base_throughput >= 125 && var.base_throughput <= 1000
    error_message = "EBS gp3 throughput must be between 125 and 1000 MB/s."
  }
}

variable "high_throughput" {
  type        = number
  default     = 1000
  description = "Target high throughput (MB/s) provisioned during heavy I/O workload"

  validation {
    condition     = var.high_throughput > 125 && var.high_throughput <= 1000
    error_message = "High throughput must be greater than 125 and at most 1000 MB/s."
  }
}

variable "base_iops" {
  type        = number
  default     = 3000
  description = "Baseline IOPS restored after peak workload finishes"

  validation {
    condition     = var.base_iops >= 3000 && var.base_iops <= 16000
    error_message = "EBS gp3 IOPS must be between 3000 and 16000."
  }
}

variable "high_iops" {
  type        = number
  default     = 4000
  description = "Target IOPS provisioned during scale-up (minimum 4000 required for 1000 MB/s on gp3)"

  validation {
    condition     = var.high_iops >= 4000 && var.high_iops <= 16000
    error_message = "To achieve 1000 MB/s on gp3, high_iops must be at least 4000 (max 0.25 MB/s per IOPS)."
  }
}

variable "scale_up_threshold_mbps" {
  type        = number
  default     = 105
  description = "Throughput threshold (MB/s) triggering scale-up alarm"
}

variable "scale_down_threshold_mbps" {
  type        = number
  default     = 85
  description = "Throughput threshold (MB/s) allowing scale-down back to baseline"

  validation {
    condition     = var.scale_down_threshold_mbps < 105
    error_message = "scale_down_threshold_mbps must be strictly lower than scale_up_threshold_mbps (105 MB/s) to prevent flapping and self-induced throttling."
  }
}

variable "min_minutes_before_scaledown" {
  type        = number
  default     = 60
  description = "Minimum hold time (in minutes) after scale-up before evaluating scale-down"

  validation {
    condition     = var.min_minutes_before_scaledown >= 30
    error_message = "Production hold window must be at least 30 minutes to prevent token exhaustion during multi-stage batch jobs."
  }
}

variable "lookback_minutes" {
  type        = number
  default     = 60
  description = "CloudWatch metric evaluation window (in minutes) required to be below threshold before scale-down"
}

variable "scaledown_check_schedule" {
  type        = string
  default     = "rate(30 minutes)"
  description = "EventBridge schedule expression for periodic scale-down evaluation"
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
