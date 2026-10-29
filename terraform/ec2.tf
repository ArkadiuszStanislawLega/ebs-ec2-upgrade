data "aws_ssm_parameter" "ubuntu_2404_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_ebs_volume" "poc_oracle_data" {
  availability_zone = var.availability_zone
  size              = 40
  type              = "gp3"
  throughput        = 125
  iops              = 3000
  encrypted         = true

  tags = {
    Name = "poc-v2-oracle-oradata-vol"
  }

  lifecycle {
    ignore_changes = [
      throughput,
      iops,
    ]
  }
}

resource "aws_instance" "poc_db_host" {
  ami                         = data.aws_ssm_parameter.ubuntu_2404_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.poc_public.id
  vpc_security_group_ids      = [aws_security_group.poc_ec2_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.poc_ec2_profile.name
  associate_public_ip_address = true
  ebs_optimized               = true
  user_data_replace_on_change = false

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 16
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    volume_id          = aws_ebs_volume.poc_oracle_data.id
    alarm_name         = aws_cloudwatch_metric_alarm.ebs_throughput_high.alarm_name
    aws_region         = var.aws_region
    load_controller_py = file("${path.module}/../src/poc_load_controller.py")
  })

  tags = {
    Name = "poc-v2-oracle-db-host"
  }
}

resource "aws_volume_attachment" "oradata_attach" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.poc_oracle_data.id
  instance_id = aws_instance.poc_db_host.id
}
