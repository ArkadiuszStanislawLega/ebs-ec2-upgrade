variable "aws_region" {
  type        = string
  default     = "eu-central-1"
  description = "Region AWS dla laboratorium PoC"
}

variable "availability_zone" {
  type        = string
  default     = "eu-central-1a"
  description = "Strefa dostepnosci dla EC2 i wolumenu EBS"
}

variable "instance_type" {
  type        = string
  default     = "c6i.large"
  description = "Typ instancji EC2: c6i.large (pelne 1000 MB/s w OS, ~$0.78/8h) lub t3.small (limit 260 MB/s w OS, ~$0.19/8h)"
}

variable "min_hours_before_scaledown" {
  type        = number
  default     = 6.05
  description = "Czas histerezy przed zbiciem (6.05h = 6h karencji AWS + 3 minuty bufora na szybki test PoC)"
}
