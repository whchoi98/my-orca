# Orca on its own VPC, ALB and EC2. Terraform counterpart of infra-cdk/lib/orca-stack.ts
# (OrcaServerStack). For an existing server, see ../attach.
#
#   CloudFront (HTTPS) -> ALB (HTTP:80, CloudFront prefix list SG + X-Custom-Secret)
#     -> Orca EC2 (HTTP/WS:6768, private subnet)

data "aws_partition" "current" {}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

locals {
  pairing_address = "wss://${module.front_door.domain_name}"
}

# -------------------------------------------------------
# Security groups
#   ALB SG : inbound 80 only from the CloudFront origin-facing prefix list
#   EC2 SG : inbound 6768 (and 6769 with the gate) only from the ALB SG
# -------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB SG - CloudFront origin-facing only"
  vpc_id      = local.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from CloudFront origin-facing only"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_security_group" "orca" {
  name        = "${var.name}-orca-sg"
  description = "Orca EC2 SG - ALB traffic only"
  vpc_id      = local.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "orca_all" {
  security_group_id = aws_security_group.orca.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "orca_from_alb" {
  security_group_id            = aws_security_group.orca.id
  description                  = "Orca from ALB"
  ip_protocol                  = "tcp"
  from_port                    = module.routes.orca_port
  to_port                      = module.routes.orca_port
  referenced_security_group_id = aws_security_group.alb.id
}

# The ALB only ever talks to the Orca host.
resource "aws_vpc_security_group_egress_rule" "alb_to_orca" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to Orca"
  ip_protocol                  = "tcp"
  from_port                    = module.routes.orca_port
  to_port                      = module.routes.orca_port
  referenced_security_group_id = aws_security_group.orca.id
}

resource "aws_vpc_security_group_ingress_rule" "gate_from_alb" {
  count                        = var.password_gate ? 1 : 0
  security_group_id            = aws_security_group.orca.id
  description                  = "Password setup service from ALB"
  ip_protocol                  = "tcp"
  from_port                    = module.routes.gate_setup_port
  to_port                      = module.routes.gate_setup_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_gate" {
  count                        = var.password_gate ? 1 : 0
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB to password setup service"
  ip_protocol                  = "tcp"
  from_port                    = module.routes.gate_setup_port
  to_port                      = module.routes.gate_setup_port
  referenced_security_group_id = aws_security_group.orca.id
}

# -------------------------------------------------------
# IAM role for EC2 (SSM + CloudWatch + Bedrock invoke for coding agents)
# -------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# IAM is global: the region in the name avoids clashing with the same deployment in another region.
resource "aws_iam_role" "orca" {
  name               = "${var.name}-orca-role-${var.region}"
  description        = "Orca server EC2 role - SSM + CloudWatch + Bedrock invoke"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(["AmazonSSMManagedInstanceCore", "CloudWatchAgentServerPolicy"])
  role       = aws_iam_role.orca.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.key}"
}

data "aws_iam_policy_document" "bedrock" {
  statement {
    sid = "BedrockInvokeForCodingAgents"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
      "bedrock:CountTokens",
      "bedrock:ListFoundationModels",
      "bedrock:GetFoundationModel",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bedrock" {
  name   = "bedrock-invoke"
  role   = aws_iam_role.orca.id
  policy = data.aws_iam_policy_document.bedrock.json
}

resource "aws_iam_role_policy" "gate" {
  count  = var.password_gate ? 1 : 0
  name   = "password-gate-setup"
  role   = aws_iam_role.orca.id
  policy = module.front_door.gate_host_policy_json
}

resource "aws_iam_instance_profile" "orca" {
  name = aws_iam_role.orca.name
  role = aws_iam_role.orca.name
}

# -------------------------------------------------------
# ALB: default 403, forward only when X-Custom-Secret matches (module.routes)
# -------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = local.alb_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  # WebSocket sessions stay open for hours; Orca also heartbeats every 15s.
  idle_timeout               = 3600
  drop_invalid_header_fields = true
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Access Denied"
      status_code  = "403"
    }
  }
}

# -------------------------------------------------------
# Front door: header secret, password gate, CloudFront. Created before the instance so its
# domain can be baked into the Orca pairing address.
# -------------------------------------------------------
module "front_door" {
  source = "../modules/front-door"

  name          = var.name
  alb_dns_name  = aws_lb.this.dns_name
  password_gate = var.password_gate
}

# -------------------------------------------------------
# EC2 instance (private subnet)
# -------------------------------------------------------
data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

locals {
  ami_arch = contains(data.aws_ec2_instance_type.this.supported_architectures, "arm64") ? "arm64" : "x86_64"
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.ami_arch}"
}

resource "aws_instance" "orca" {
  ami                    = data.aws_ssm_parameter.al2023.insecure_value
  instance_type          = var.instance_type
  subnet_id              = local.instance_subnet_id
  vpc_security_group_ids = [aws_security_group.orca.id]
  iam_instance_profile   = aws_iam_instance_profile.orca.name

  # Setup runs from a systemd oneshot unit that re-runs on every boot until it is done, because
  # an SSM patch association can reboot a fresh instance in the middle of it. Same script as
  # the CDK stack's UserData.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    orca_version    = var.orca_version
    pairing_address = local.pairing_address
    region          = var.region
    orca_port       = module.routes.orca_port
    gate_enabled    = var.password_gate
    gate_kvs_arn    = module.front_door.gate_kvs_arn
    gate_bundle_url = module.front_door.gate_bundle_url
  })

  # No metadata_options: AL2023 AMIs already default to IMDSv2-only with hop limit 2, which
  # Docker containers need.
  root_block_device {
    volume_size = 100
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.name}-orca-server"
  }

  lifecycle {
    # A newly published AMI would replace the instance, and with it the EBS volume that holds
    # the user's repositories. UserData only runs at first boot, so a changed orca_version must
    # not restart the instance either. Rebuild deliberately with:
    #   terraform apply -replace=aws_instance.orca
    ignore_changes = [ami, user_data]
  }

  depends_on = [
    aws_iam_role_policy.gate,
    aws_iam_role_policy_attachment.managed,
    aws_route.private_nat,
    aws_route_table_association.private,
    aws_vpc_endpoint.ssm,
  ]
}

module "routes" {
  source = "../modules/routes"

  name                = var.name
  vpc_id              = local.vpc_id
  listener_arn        = aws_lb_listener.http.arn
  instance_id         = aws_instance.orca.id
  origin_secret_value = module.front_door.origin_secret_value
  gate_enabled        = var.password_gate
}
