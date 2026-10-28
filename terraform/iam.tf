data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

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
  name               = "poc-ebs-scaler-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "ebs_scaler_permissions" {
  statement {
    sid       = "ModifySpecificDataVolumeOnly"
    effect    = "Allow"
    actions   = ["ec2:ModifyVolume"]
    resources = [aws_ebs_volume.poc_oracle_data.arn]
  }

  statement {
    sid    = "DescribeVolumesAndMetrics"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumesModifications",
      "cloudwatch:GetMetricData"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogsWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.scaler_logs.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ebs_scaler_policy" {
  name   = "poc-ebs-scaler-least-privilege"
  role   = aws_iam_role.ebs_scaler_role.id
  policy = data.aws_iam_policy_document.ebs_scaler_permissions.json
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "poc_ec2_role" {
  name               = "poc-ebs-scaler-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.poc_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "ec2_telemetry_read" {
  statement {
    sid    = "ReadOnlyTelemetryForTerminalDisplay"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumesModifications",
      "cloudwatch:DescribeAlarms"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2_telemetry_policy" {
  name   = "poc-ec2-telemetry-readonly"
  role   = aws_iam_role.poc_ec2_role.id
  policy = data.aws_iam_policy_document.ec2_telemetry_read.json
}

resource "aws_iam_instance_profile" "poc_ec2_profile" {
  name = "poc-ebs-scaler-ec2-profile"
  role = aws_iam_role.poc_ec2_role.name
}
