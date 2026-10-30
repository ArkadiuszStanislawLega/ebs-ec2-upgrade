data "aws_ebs_volume" "managed_volumes" {
  for_each = var.volumes

  filter {
    name   = "volume-id"
    values = [each.key]
  }

  filter {
    name   = "status"
    values = ["in-use"]
  }

  lifecycle {
    postcondition {
      condition     = self.volume_type == "gp3"
      error_message = "ARCHITECTURE ERROR: Volume ${each.key} is of type '${self.volume_type}'. Only gp3 volumes are supported."
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
  name               = "${var.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ebs_scaler_permissions" {
  statement {
    sid       = "ModifyEnrolledVolumesOnly"
    effect    = "Allow"
    actions   = ["ec2:ModifyVolume"]
    resources = [for vol in data.aws_ebs_volume.managed_volumes : vol.arn]
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
  name   = "${var.name_prefix}-least-privilege"
  role   = aws_iam_role.ebs_scaler_role.id
  policy = data.aws_iam_policy_document.ebs_scaler_permissions.json
}
