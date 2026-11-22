# Orca on an existing server behind an existing ALB, e.g. ec2_vscode's VS Code server.
# Terraform counterpart of infra-cdk/lib/orca-attach-stack.ts (OrcaOnVscodeStack).
#
#   new CloudFront (+ password gate) -> host ALB listener: rule on Orca's own X-Custom-Secret
#     -> host EC2 :6768 (orca-serve), :6769 (first-login setup)
#
# The host's own resources are only read. Everything here is added beside them (listener rules,
# security group rules, an inline policy on the host role) and removed by terraform destroy.
# Orca itself is installed over SSM Run Command, so the host keeps running throughout.
#
# One host takes one Orca deployment: do not apply this to a server that already has the CDK
# stack (or another copy of this configuration) attached.

# -------------------------------------------------------
# Host resources (read only)
# -------------------------------------------------------
data "aws_instance" "host" {
  instance_id = var.host_instance_id

  lifecycle {
    postcondition {
      condition     = var.host_instance_security_group_id != null || length(self.vpc_security_group_ids) == 1
      error_message = "The host has more than one security group. Set host_instance_security_group_id to the one that should admit the ALB."
    }
    postcondition {
      condition     = self.iam_instance_profile != ""
      error_message = "The host has no instance profile. Orca is installed over SSM, which needs one."
    }
  }
}

data "aws_lb_listener" "host" {
  arn = var.host_listener_arn

  lifecycle {
    postcondition {
      condition     = self.port == 80 && self.protocol == "HTTP"
      error_message = "The host listener must be HTTP:80. CloudFront connects to its origin over HTTP:80."
    }
  }
}

data "aws_lb" "host" {
  arn = data.aws_lb_listener.host.load_balancer_arn

  lifecycle {
    postcondition {
      condition     = var.host_alb_security_group_id != null || length(self.security_groups) == 1
      error_message = "The host ALB has more than one security group. Set host_alb_security_group_id to the one its traffic comes from."
    }
  }
}

data "aws_iam_instance_profile" "host" {
  name = data.aws_instance.host.iam_instance_profile
}

locals {
  host_label = var.host_label != "" ? var.host_label : var.host_instance_id
  # An explicit ID wins. Without one there must be exactly one group (the postconditions above
  # report it otherwise); try() keeps one() from failing first when there are several.
  instance_sg_id      = var.host_instance_security_group_id != null ? var.host_instance_security_group_id : try(one(data.aws_instance.host.vpc_security_group_ids), null)
  alb_sg_id           = var.host_alb_security_group_id != null ? var.host_alb_security_group_id : try(one(data.aws_lb.host.security_groups), null)
  host_role_name      = data.aws_iam_instance_profile.host.role_name
  pairing_address     = "wss://${module.front_door.domain_name}"
  host_scripts_dir    = "${path.module}/../../infra-cdk/lib/host"
  host_scripts_sha256 = sha256(join("", [for name in ["install_orca.sh", "uninstall_orca.sh"] : file("${local.host_scripts_dir}/${name}")]))
  ssm_run             = "${path.module}/../scripts/ssm_run.sh"
  install_environment = {
    ORCA_VERSION         = var.orca_version
    ORCA_PAIRING_ADDRESS = local.pairing_address
    ORCA_REGION          = var.region
    ORCA_USER            = var.host_user
    GATE_KVS_ARN         = module.front_door.gate_kvs_arn
    GATE_BUNDLE_URL      = module.front_door.gate_bundle_url
  }
}

# -------------------------------------------------------
# Security group rules on the host instance, removed with this deployment.
# The ALB's own security group is not changed.
# -------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "orca_from_alb" {
  security_group_id            = local.instance_sg_id
  description                  = "Orca from ALB (${var.name})"
  ip_protocol                  = "tcp"
  from_port                    = module.routes.orca_port
  to_port                      = module.routes.orca_port
  referenced_security_group_id = local.alb_sg_id
}

resource "aws_vpc_security_group_ingress_rule" "gate_from_alb" {
  count                        = var.password_gate ? 1 : 0
  security_group_id            = local.instance_sg_id
  description                  = "Orca password setup from ALB (${var.name})"
  ip_protocol                  = "tcp"
  from_port                    = module.routes.gate_setup_port
  to_port                      = module.routes.gate_setup_port
  referenced_security_group_id = local.alb_sg_id
}

# -------------------------------------------------------
# Front door: Orca's own header secret, password gate and CloudFront
# -------------------------------------------------------
module "front_door" {
  source = "../modules/front-door"

  name          = var.name
  alb_dns_name  = data.aws_lb.host.dns_name
  password_gate = var.password_gate
}

resource "aws_iam_role_policy" "host_gate" {
  count  = var.password_gate ? 1 : 0
  name   = "${var.name}-password-gate-setup"
  role   = local.host_role_name
  policy = module.front_door.gate_host_policy_json
}

module "routes" {
  source = "../modules/routes"

  name                = var.name
  vpc_id              = data.aws_lb.host.vpc_id
  listener_arn        = var.host_listener_arn
  instance_id         = var.host_instance_id
  origin_secret_value = module.front_door.origin_secret_value
  gate_enabled        = var.password_gate
  gate_setup_priority = var.gate_setup_rule_priority
  orca_priority       = var.orca_rule_priority
}

# -------------------------------------------------------
# Install orca-serve on the host (SSM Run Command, ../scripts/ssm_run.sh)
# -------------------------------------------------------
# Two resources, because Terraform replaces a resource by destroying it first:
#   host_uninstall  lives as long as Orca is on this instance. Only its destroy provisioner
#                   does anything: it runs uninstall_orca.sh on terraform destroy, or when the
#                   deployment moves to another instance.
#   host_install    is replaced whenever an input of install_orca.sh changes (version, pairing
#                   address, gate, the scripts themselves), which re-runs the install in place.
#                   It has no destroy provisioner, so an upgrade never uninstalls first.
# There is no rollback as in CloudFormation: a failed install leaves the host where the script
# stopped and marks host_install as tainted, so the next apply runs it again.
resource "terraform_data" "host_uninstall" {
  triggers_replace = [var.host_instance_id]

  input = {
    instance_id = var.host_instance_id
    region      = var.region
    user        = var.host_user
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash \"${path.module}/../scripts/ssm_run.sh\" uninstall \"${path.module}/../../infra-cdk/lib/host/uninstall_orca.sh\""

    environment = {
      ORCA_INSTANCE_ID = self.input.instance_id
      AWS_REGION       = self.input.region
      ORCA_USER        = self.input.user
    }
  }
}

resource "terraform_data" "host_install" {
  triggers_replace = [
    var.host_instance_id,
    local.install_environment,
    local.host_scripts_sha256,
  ]

  provisioner "local-exec" {
    command = "bash \"${local.ssm_run}\" install \"${local.host_scripts_dir}/install_orca.sh\""

    environment = merge(local.install_environment, {
      ORCA_INSTANCE_ID = var.host_instance_id
      AWS_REGION       = var.region
    })
  }

  depends_on = [
    terraform_data.host_uninstall,
    # The host role's new policy (S3 bundle, KeyValueStore) must exist before the install runs.
    aws_iam_role_policy.host_gate,
  ]
}
