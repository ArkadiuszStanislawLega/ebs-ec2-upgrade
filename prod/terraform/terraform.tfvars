aws_region                   = "eu-central-1"
name_prefix                  = "oracle-ebs-scaler"
scaledown_check_schedule     = "rate(30 minutes)"
log_retention_days           = 90

volumes = {
  "vol-064e6d89476c13901" = {}
  "vol-0945bbe05c05303f8" = {}
  "vol-0db821692bb4af333" = {}
  "vol-054f0845ca6b9a7f0" = {} 
  "vol-0301418407d844f08" = {}
  "vol-08c341c5a04ec82c1" = {}
  "vol-08023b421c6d50ac6" = {}
}

tags = {
  Project     = "Oracle-EBS-AutoThroughput"
  ManagedBy   = "Terraform"
  Environment = "production"
}
