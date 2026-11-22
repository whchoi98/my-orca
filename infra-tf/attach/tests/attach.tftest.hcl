# Plans against a mock AWS provider: no AWS calls, no credentials.
# Run: bash infra-tf/run-tests.sh   (or terraform -chdir=infra-tf/attach test)
# Every run is plan-only on purpose: an apply would run the local-exec provisioner, and with it
# ssm_run.sh against real AWS. ssm_run.sh has its own test (../test/ssm_run_test.py).

mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  host_instance_id  = "i-0123456789abcdef0"
  host_listener_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/host/0123456789abcdef/0123456789abcdef"
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.orca_from_alb.security_group_id == "sg-0123456789abcdef0" && aws_vpc_security_group_ingress_rule.orca_from_alb.referenced_security_group_id == "sg-0123456789abcdef1"
    error_message = "The host security group admits the ALB security group."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.orca_from_alb.from_port == 6768 && aws_vpc_security_group_ingress_rule.orca_from_alb.to_port == 6768 && aws_vpc_security_group_ingress_rule.orca_from_alb.cidr_ipv4 == null
    error_message = "Only 6768 is opened, and only to the ALB security group."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.gate_from_alb[0].from_port == 6769 && aws_vpc_security_group_ingress_rule.gate_from_alb[0].referenced_security_group_id == "sg-0123456789abcdef1"
    error_message = "With the gate, 6769 is opened to the ALB security group."
  }
  assert {
    condition     = aws_iam_role_policy.host_gate[0].role == "host-role"
    error_message = "The setup service policy goes on the host's own role."
  }
  assert {
    condition     = output.instance_id == "i-0123456789abcdef0" && output.host == "i-0123456789abcdef0" && output.alb_endpoint == "http://host-alb.example.test"
    error_message = "Outputs describe the host."
  }
  assert {
    condition     = output.orca_version == "1.4.269"
    error_message = "The default Orca version differs from the CDK stacks."
  }
  # The uninstall marker is replaced, and so runs uninstall_orca.sh, only when the deployment
  # moves to another instance. A version change must not reach it.
  assert {
    condition     = length(terraform_data.host_uninstall.triggers_replace) == 1 && terraform_data.host_uninstall.triggers_replace[0] == "i-0123456789abcdef0"
    error_message = "host_uninstall must be replaced only when the instance changes."
  }
  assert {
    condition     = terraform_data.host_uninstall.input.instance_id == "i-0123456789abcdef0" && terraform_data.host_uninstall.input.region == "ap-northeast-2" && terraform_data.host_uninstall.input.user == "ec2-user"
    error_message = "The destroy provisioner reads its target from the resource's own input."
  }
  assert {
    condition     = terraform_data.host_install.triggers_replace[1].ORCA_VERSION == "1.4.269" && terraform_data.host_install.triggers_replace[1].ORCA_USER == "ec2-user" && terraform_data.host_install.triggers_replace[1].ORCA_REGION == "ap-northeast-2"
    error_message = "The install re-runs when one of its inputs changes."
  }
  assert {
    condition     = terraform_data.host_install.triggers_replace[2] == sha256("${file("../../infra-cdk/lib/host/install_orca.sh")}${file("../../infra-cdk/lib/host/uninstall_orca.sh")}")
    error_message = "The install re-runs when a host script changes."
  }
}

run "an_upgrade_reinstalls_in_place" {
  command = plan

  variables {
    orca_version = "1.5.0"
  }

  assert {
    condition     = terraform_data.host_install.triggers_replace[1].ORCA_VERSION == "1.5.0"
    error_message = "A new version reaches the install."
  }
  assert {
    condition     = length(terraform_data.host_uninstall.triggers_replace) == 1 && terraform_data.host_uninstall.triggers_replace[0] == "i-0123456789abcdef0"
    error_message = "A new version must not replace host_uninstall (that would uninstall Orca first)."
  }
}

run "gate_off" {
  command = plan

  variables {
    password_gate = false
  }

  assert {
    condition     = length(aws_iam_role_policy.host_gate) == 0 && length(aws_vpc_security_group_ingress_rule.gate_from_alb) == 0
    error_message = "Without the gate the host role and port 6769 are left alone."
  }
  assert {
    condition     = terraform_data.host_install.triggers_replace[1].GATE_KVS_ARN == "" && terraform_data.host_install.triggers_replace[1].GATE_BUNDLE_URL == ""
    error_message = "Without the gate the install gets empty gate inputs, which removes the setup service."
  }
  assert {
    condition     = output.password_gate_store_arn == ""
    error_message = "Without the gate the store output is empty."
  }
}

run "explicit_security_groups_and_label" {
  command = plan

  variables {
    host_instance_security_group_id = "sg-0123456789abcdef2"
    host_alb_security_group_id      = "sg-0123456789abcdef3"
    host_label                      = "VscodeServerStack"
    host_user                       = "coder"
  }

  override_data {
    target = data.aws_instance.host
    values = {
      vpc_security_group_ids = ["sg-0123456789abcdef0", "sg-0123456789abcdef2"]
      iam_instance_profile   = "host-profile"
    }
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.orca_from_alb.security_group_id == "sg-0123456789abcdef2" && aws_vpc_security_group_ingress_rule.orca_from_alb.referenced_security_group_id == "sg-0123456789abcdef3"
    error_message = "Explicit security groups win over the looked up ones."
  }
  assert {
    condition     = output.host == "VscodeServerStack" && terraform_data.host_uninstall.input.user == "coder" && terraform_data.host_install.triggers_replace[1].ORCA_USER == "coder"
    error_message = "The label and the user are passed through, to the install and to the uninstall."
  }
}

run "a_host_with_two_security_groups_needs_a_choice" {
  command = plan

  override_data {
    target = data.aws_instance.host
    values = {
      vpc_security_group_ids = ["sg-0123456789abcdef0", "sg-0123456789abcdef2"]
      iam_instance_profile   = "host-profile"
    }
  }

  expect_failures = [data.aws_instance.host]
}

run "a_host_without_an_instance_profile_is_refused" {
  command = plan

  override_data {
    target = data.aws_instance.host
    values = {
      vpc_security_group_ids = ["sg-0123456789abcdef0"]
      iam_instance_profile   = ""
    }
  }

  expect_failures = [data.aws_instance.host]
}

run "a_listener_that_is_not_http_80_is_refused" {
  command = plan

  override_data {
    target = data.aws_lb_listener.host
    values = {
      port              = 443
      protocol          = "HTTPS"
      load_balancer_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/host/0123456789abcdef"
    }
  }

  expect_failures = [data.aws_lb_listener.host]
}

run "a_listener_on_port_80_that_is_not_http_is_refused" {
  command = plan

  override_data {
    target = data.aws_lb_listener.host
    values = {
      port              = 80
      protocol          = "HTTPS"
      load_balancer_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/host/0123456789abcdef"
    }
  }

  expect_failures = [data.aws_lb_listener.host]
}

run "an_http_listener_on_another_port_is_refused" {
  command = plan

  override_data {
    target = data.aws_lb_listener.host
    values = {
      port              = 8080
      protocol          = "HTTP"
      load_balancer_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/host/0123456789abcdef"
    }
  }

  expect_failures = [data.aws_lb_listener.host]
}

run "rejects_a_malformed_instance_id" {
  command = plan

  variables {
    host_instance_id = "VscodeServerStack"
  }

  expect_failures = [var.host_instance_id]
}

run "rejects_a_listener_arn_of_another_kind" {
  command = plan

  variables {
    host_listener_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/host/0123456789abcdef"
  }

  expect_failures = [var.host_listener_arn]
}

run "rejects_a_malformed_version" {
  command = plan

  variables {
    orca_version = "latest"
  }

  expect_failures = [var.orca_version]
}
