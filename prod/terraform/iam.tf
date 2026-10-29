data "aws_ebs_volume" "target_oracle_vol" {
  filter {
    name   = "volume-id"
    values = [var.volume_id]
  }

  lifecycle {
    postcondition {
      condition     = self.volume_type == "gp3"
      error_message = "ARCHITECTURE ERROR: Volume ${var.volume_id} is of type '${self.volume_type}'. Only gp3 volumes are supported."
    }
    postcondition {
      condition     = self.state == "in-use"
      error_message = "OPERATIONAL ERROR: Volume ${var.volume_id} is in state '${self.state}' instead of 'in-use'."
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_scaler_role" {
  name               = "ebs-throughput-scaler-role-${var.volume_id}"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ebs_scaler_permissions" {
  statement {
    sid       = "ModifyTargetVolumeOnly"
    effect    = "Allow"
    actions   = ["ec2:ModifyVolume"]
    resources = [data.aws_ebs_volume.target_oracle_vol.arn]
  }

  statement {
    sid    = "ReadVolumeAndCloudWatchTelemetry"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumesModifications",
      "cloudwatch:GetMetricData",
      "cloudwatch:DescribeAlarms"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "WriteLambdaLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.scaler_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ebs_scaler_policy" {
  name   = "ebs-scaler-least-privilege"
  role   = aws_iam_role.ebs_scaler_role.id
  policy = data.aws_iam_policy_document.ebs_scaler_permissions.json
}
