# The default deployment, applied against a mock AWS provider: no AWS calls, no credentials.
# Run: bash infra-tf/run-tests.sh   (or terraform -chdir=infra-tf/dedicated test)
# The runs share one state, so the second run sees the instance the first one made.

mock_provider "aws" {
  source = "./tests/mocks"
}

run "defaults" {
  command = apply

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_cloudfront.prefix_list_id == "pl-0123456789abcdef0"
    error_message = "The ALB must admit the CloudFront origin-facing prefix list."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_cloudfront.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.alb_from_cloudfront.cidr_ipv6 == null
    error_message = "The ALB must not be open to an address range."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_from_cloudfront.from_port == 80 && aws_vpc_security_group_ingress_rule.alb_from_cloudfront.to_port == 80
    error_message = "The ALB takes HTTP:80 from CloudFront."
  }
  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "fixed-response" && aws_lb_listener.http.default_action[0].fixed_response[0].status_code == "403"
    error_message = "The listener must answer 403 unless a rule matches."
  }
  assert {
    condition     = aws_lb.this.idle_timeout == 3600 && aws_lb.this.drop_invalid_header_fields && !aws_lb.this.internal
    error_message = "ALB settings differ from the CDK stack."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.orca_from_alb.from_port == 6768 && aws_vpc_security_group_ingress_rule.orca_from_alb.referenced_security_group_id == aws_security_group.alb.id
    error_message = "The Orca host takes 6768 only from the ALB security group."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.gate_from_alb[0].from_port == 6769 && aws_vpc_security_group_egress_rule.alb_to_gate[0].from_port == 6769
    error_message = "With the gate, 6769 is open between the ALB and the host."
  }
  assert {
    condition     = aws_instance.orca.root_block_device[0].encrypted && aws_instance.orca.root_block_device[0].volume_size == 100 && aws_instance.orca.root_block_device[0].volume_type == "gp3"
    error_message = "The root volume must be 100 GB gp3, encrypted."
  }
  assert {
    condition     = data.aws_ssm_parameter.al2023.name == "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
    error_message = "A Graviton instance type must get the arm64 AMI."
  }
  assert {
    condition     = strcontains(aws_instance.orca.user_data, "ORCA_VERSION=\"1.4.269\"")
    error_message = "UserData must install the default Orca version."
  }
  assert {
    condition     = strcontains(aws_instance.orca.user_data, "ORCA_PAIRING_ADDRESS=${output.pairing_address}") && startswith(output.pairing_address, "wss://")
    error_message = "UserData must carry the CloudFront pairing address."
  }
  assert {
    condition     = strcontains(aws_instance.orca.user_data, "serve --port 6768 --bind 0.0.0.0 --pairing-address \\$${ORCA_PAIRING_ADDRESS}")
    error_message = "orca-serve must listen on 6768 with the pairing address from serve.env."
  }
  assert {
    condition     = strcontains(aws_instance.orca.user_data, "bash /opt/orca-gate-src/install.sh \"${output.password_gate_store_arn}\" \"${var.region}\"")
    error_message = "With the gate, UserData installs the first-login setup service."
  }
  assert {
    condition     = strcontains(aws_instance.orca.user_data, "rpm -q --qf \"%%{VERSION}\" orca-ide")
    error_message = "The rpm query format must survive the template untouched."
  }
  assert {
    condition     = length(aws_vpc.this) == 1 && length(aws_nat_gateway.this) == 1 && length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2
    error_message = "A new VPC has two public and two private subnets and one NAT gateway."
  }
  assert {
    condition     = aws_subnet.public[0].cidr_block == "10.253.0.0/24" && aws_subnet.private[1].cidr_block == "10.253.3.0/24"
    error_message = "Subnets are /24, public first, as in the CDK stack."
  }
  assert {
    condition     = length(aws_vpc_endpoint.ssm) == 3
    error_message = "The three SSM interface endpoints are created by default."
  }
  assert {
    condition     = length(aws_iam_role_policy.gate) == 1 && output.password_gate_store_arn != "" && startswith(output.password_gate_setup_bundle, "s3://")
    error_message = "With the gate, the role can read the store and the bundle."
  }
}

# orca_version is the version installed at first boot. Changing it later must not touch the
# instance: UserData does not run again, and a restart would only interrupt the user.
run "a_new_version_leaves_the_running_instance_alone" {
  command = apply

  variables {
    orca_version = "9.9.9"
  }

  assert {
    condition     = strcontains(aws_instance.orca.user_data, "ORCA_VERSION=\"1.4.269\"") && !strcontains(aws_instance.orca.user_data, "9.9.9")
    error_message = "A changed orca_version must not rewrite the UserData of an existing instance."
  }
  assert {
    condition     = output.orca_version == "9.9.9"
    error_message = "The output reports the configured version."
  }
}
