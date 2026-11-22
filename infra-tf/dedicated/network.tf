# VPC: a new one (two public and two private /24 subnets, one NAT gateway) or an existing one
# passed in with vpc_id, alb_subnet_ids and instance_subnet_id.

locals {
  create_vpc = var.vpc_id == null
  # /24 subnets, as in the CDK stack (cidrMask 24).
  subnet_newbits = 24 - tonumber(split("/", var.vpc_cidr)[1])
}

data "aws_availability_zones" "available" {
  count = local.create_vpc ? 1 : 0
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "this" {
  count                = local.create_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = var.vpc_name
  }
}

resource "aws_internet_gateway" "this" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = {
    Name = var.vpc_name
  }
}

resource "aws_subnet" "public" {
  count                   = local.create_vpc ? 2 : 0
  vpc_id                  = aws_vpc.this[0].id
  availability_zone       = data.aws_availability_zones.available[0].names[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, local.subnet_newbits, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.vpc_name}-public-${count.index + 1}"
  }
}

resource "aws_subnet" "private" {
  count             = local.create_vpc ? 2 : 0
  vpc_id            = aws_vpc.this[0].id
  availability_zone = data.aws_availability_zones.available[0].names[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, local.subnet_newbits, count.index + 2)

  tags = {
    Name = "${var.vpc_name}-private-${count.index + 1}"
  }
}

resource "aws_eip" "nat" {
  count  = local.create_vpc ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "${var.vpc_name}-nat"
  }
}

resource "aws_nat_gateway" "this" {
  count         = local.create_vpc ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = var.vpc_name
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = {
    Name = "${var.vpc_name}-public"
  }
}

resource "aws_route" "public_internet" {
  count                  = local.create_vpc ? 1 : 0
  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  count          = local.create_vpc ? 2 : 0
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count  = local.create_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id

  tags = {
    Name = "${var.vpc_name}-private"
  }
}

resource "aws_route" "private_nat" {
  count                  = local.create_vpc ? 1 : 0
  route_table_id         = aws_route_table.private[0].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

resource "aws_route_table_association" "private" {
  count          = local.create_vpc ? 2 : 0
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

data "aws_vpc" "existing" {
  count = local.create_vpc ? 0 : 1
  id    = var.vpc_id

  lifecycle {
    postcondition {
      condition     = length(var.alb_subnet_ids) >= 2 && var.instance_subnet_id != null
      error_message = "With vpc_id, set alb_subnet_ids (public subnets in two or more Availability Zones) and instance_subnet_id (a private subnet with outbound internet access)."
    }
  }
}

locals {
  vpc_id              = local.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id
  vpc_cidr_block      = local.create_vpc ? aws_vpc.this[0].cidr_block : data.aws_vpc.existing[0].cidr_block
  alb_subnet_ids      = local.create_vpc ? aws_subnet.public[*].id : var.alb_subnet_ids
  instance_subnet_id  = local.create_vpc ? aws_subnet.private[0].id : var.instance_subnet_id
  endpoint_subnet_ids = local.create_vpc ? aws_subnet.private[*].id : [var.instance_subnet_id]
}

# -------------------------------------------------------
# SSM VPC endpoints (create_ssm_endpoints = false when the VPC already has them)
# -------------------------------------------------------
resource "aws_security_group" "ssm" {
  count       = var.create_ssm_endpoints ? 1 : 0
  name        = "${var.name}-ssm-endpoints-sg"
  description = "SSM VPC Endpoints SG - HTTPS from VPC CIDR"
  vpc_id      = local.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "ssm_https" {
  count             = var.create_ssm_endpoints ? 1 : 0
  security_group_id = aws_security_group.ssm[0].id
  description       = "HTTPS from VPC CIDR"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = local.vpc_cidr_block
}

resource "aws_vpc_security_group_egress_rule" "ssm_all" {
  count             = var.create_ssm_endpoints ? 1 : 0
  security_group_id = aws_security_group.ssm[0].id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_endpoint" "ssm" {
  for_each            = var.create_ssm_endpoints ? toset(["ssm", "ssmmessages", "ec2messages"]) : toset([])
  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.endpoint_subnet_ids
  security_group_ids  = [aws_security_group.ssm[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name}-${each.key}"
  }
}
