data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Security group ---------------------------------------------------------
resource "aws_security_group" "coturn" {
  name        = "${var.name_prefix}-coturn-sg"
  description = "coturn TURN server"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-coturn-sg" }
}

locals {
  turn_ports = [3478, 5349]
}

resource "aws_security_group_rule" "turn_udp" {
  for_each          = toset([for p in local.turn_ports : tostring(p)])
  type              = "ingress"
  security_group_id = aws_security_group.coturn.id
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "TURN ${each.value}/udp"
}

resource "aws_security_group_rule" "turn_tcp" {
  for_each          = toset([for p in local.turn_ports : tostring(p)])
  type              = "ingress"
  security_group_id = aws_security_group.coturn.id
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "TURN ${each.value}/tcp"
}

resource "aws_security_group_rule" "turn_relay" {
  type              = "ingress"
  security_group_id = aws_security_group.coturn.id
  from_port         = var.relay_port_min
  to_port           = var.relay_port_max
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "TURN media relay range"
}

resource "aws_security_group_rule" "ssh" {
  count             = var.ssh_cidr == "" ? 0 : 1
  type              = "ingress"
  security_group_id = aws_security_group.coturn.id
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.ssh_cidr]
  description       = "SSH"
}

resource "aws_security_group_rule" "egress" {
  type              = "egress"
  security_group_id = aws_security_group.coturn.id
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

# --- IAM instance profile ---------------------------------------------------
data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "coturn" {
  name               = "${var.name_prefix}-coturn"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "coturn" {
  statement {
    sid       = "ReadTurnSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.turn_secret_arn]
  }
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup", "logs:CreateLogStream",
      "logs:PutLogEvents", "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.coturn.arn}:*"]
  }
}

resource "aws_iam_role_policy" "coturn" {
  name   = "coturn"
  role   = aws_iam_role.coturn.id
  policy = data.aws_iam_policy_document.coturn.json
}

# SSM Session Manager access (shell without opening SSH).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.coturn.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "coturn" {
  name = "${var.name_prefix}-coturn"
  role = aws_iam_role.coturn.name
}

# --- Logs -------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "coturn" {
  name              = "/coturn/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

# --- Elastic IP + instance --------------------------------------------------
resource "aws_eip" "coturn" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-coturn-eip" }
}

resource "aws_instance" "coturn" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.public_subnet_id
  vpc_security_group_ids = [aws_security_group.coturn.id]
  iam_instance_profile   = aws_iam_instance_profile.coturn.name
  key_name               = var.key_name == "" ? null : var.key_name

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    region          = var.region
    turn_secret_arn = var.turn_secret_arn
    realm           = var.realm
    relay_port_min  = var.relay_port_min
    relay_port_max  = var.relay_port_max
    eip             = aws_eip.coturn.public_ip
    log_group       = aws_cloudwatch_log_group.coturn.name
  })

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    # AL2023 AMI snapshot is 30 GB, so the root volume must be >= 30.
    volume_size = 30
    encrypted   = true
  }

  tags = { Name = "${var.name_prefix}-coturn" }

  # Re-run user_data if the rendered config changes.
  user_data_replace_on_change = true
}

resource "aws_eip_association" "coturn" {
  instance_id   = aws_instance.coturn.id
  allocation_id = aws_eip.coturn.id
}
