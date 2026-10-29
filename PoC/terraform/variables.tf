variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "Region AWS dla laboratorium PoC v2"
}

variable "availability_zone" {
  type        = string
  default     = "eu-central-1a"
  description = "Strefa dostepnosci dla EC2 i wolumenu EBS"
}

variable "instance_type" {
  type        = string
  default     = "c6i.large"
  description = "Typ instancji EC2 gwarantujacy pasmo 10 Gbps do EBS"
}

variable "min_minutes_before_scaledown" {
  type        = number
  default     = 8
  description = "Minimalny czas (w minutach) od podbicia przed pierwsza proba zbicia (8 min w PoC v2, 60 min na prod)"
}

variable "lookback_minutes" {
  type        = number
  default     = 5
  description = "Okno wstecznej analizy metryk CloudWatch w minutach (5 min w PoC v2, 60 min na prod)"
}
