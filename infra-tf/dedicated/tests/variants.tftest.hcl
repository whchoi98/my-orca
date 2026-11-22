# Other inputs, against a mock AWS provider. The plan-only runs come first, so the last run
# (apply) starts from an empty state.

mock_provider "aws" {
  source = "./tests/mocks"
}

run "x86_instance_type_gets_the_x86_ami" {
  command = plan

  variables {
    instance_type = "m7i.xlarge"
  }

  override_data {
    target = data.aws_ec2_instance_type.this
    values = {
      supported_architectures = ["x86_64"]
    }
  }

  assert {
    condition     = data.aws_ssm_parameter.al2023.name == "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
    error_message = "An x86 instance type must get the x86_64 AMI."
  }
}

run "existing_vpc" {
  command = plan

  variables {
    name                 = "orca-existing"
    vpc_id               = "vpc-0123456789abcdef0"
    alb_subnet_ids       = ["subnet-0123456789abcdef1", "subnet-0123456789abcdef2"]
    instance_subnet_id   = "subnet-0123456789abcdef3"
    create_ssm_endpoints = false
  }

  assert {
    condition     = length(aws_vpc.this) == 0 && length(aws_nat_gateway.this) == 0 && length(aws_subnet.public) == 0 && length(aws_subnet.private) == 0
    error_message = "With vpc_id no network is created."
  }
  assert {
    condition     = aws_instance.orca.subnet_id == "subnet-0123456789abcdef3" && length(aws_lb.this.subnets) == 2
    error_message = "With vpc_id the given subnets are used."
  }
  assert {
    condition     = length(aws_vpc_endpoint.ssm) == 0 && length(aws_security_group.ssm) == 0
    error_message = "create_ssm_endpoints = false creates no endpoint."
  }
}

run "existing_vpc_needs_its_subnets" {
  command = plan

  variables {
    vpc_id = "vpc-0123456789abcdef0"
  }

  expect_failures = [data.aws_vpc.existing]
}

run "rejects_a_malformed_version" {
  command = plan

  variables {
    orca_version = "v1.4"
  }

  expect_failures = [var.orca_version]
}

run "rejects_a_name_s3_cannot_take" {
  command = plan

  variables {
    name = "OrcaServerStack"
  }

  expect_failures = [var.name]
}

run "gate_off" {
  command = apply

  variables {
    name          = "orca-nogate"
    password_gate = false
  }

  assert {
    condition     = length(aws_iam_role_policy.gate) == 0 && length(aws_vpc_security_group_ingress_rule.gate_from_alb) == 0 && length(aws_vpc_security_group_egress_rule.alb_to_gate) == 0
    error_message = "Without the gate there is no 6769 rule and no gate policy."
  }
  assert {
    condition     = output.password_gate_store_arn == "" && output.password_gate_setup_bundle == ""
    error_message = "Without the gate the gate outputs are empty."
  }
  assert {
    condition     = !strcontains(aws_instance.orca.user_data, "orca-gate")
    error_message = "Without the gate UserData must not install the setup service."
  }
  assert {
    condition     = strcontains(aws_instance.orca.user_data, "touch /var/lib/orca-bootstrap/done")
    error_message = "UserData must still finish with the done marker."
  }
}
