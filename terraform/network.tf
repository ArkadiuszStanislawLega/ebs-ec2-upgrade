resource "aws_vpc" "poc_vpc" {
  cidr_block           = "10.240.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "poc-ebs-scaler-vpc"
  }
}

resource "aws_internet_gateway" "poc_igw" {
  vpc_id = aws_vpc.poc_vpc.id

  tags = {
    Name = "poc-ebs-scaler-igw"
  }
}

resource "aws_subnet" "poc_public" {
  vpc_id                  = aws_vpc.poc_vpc.id
  cidr_block              = "10.240.0.0/26"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "poc-ebs-scaler-public-subnet"
  }
}

resource "aws_route_table" "poc_public_rt" {
  vpc_id = aws_vpc.poc_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.poc_igw.id
  }
}

resource "aws_route_table_association" "poc_public_assoc" {
  subnet_id      = aws_subnet.poc_public.id
  route_table_id = aws_route_table.poc_public_rt.id
}

resource "aws_security_group" "poc_ec2_sg" {
  name        = "poc-ebs-scaler-ec2-sg"
  description = "Zero inbound ports - outbound HTTPS only for SSM and AWS API"
  vpc_id      = aws_vpc.poc_vpc.id

  egress {
    description = "Outbound HTTPS and package repos"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
