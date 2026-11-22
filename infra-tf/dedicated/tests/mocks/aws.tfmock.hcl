# Values the mock AWS provider returns, shared by the test files in this directory.

mock_data "aws_availability_zones" {
  defaults = {
    names = ["ap-northeast-2a", "ap-northeast-2b"]
  }
}

mock_data "aws_partition" {
  defaults = {
    partition = "aws"
  }
}

mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

mock_data "aws_ec2_instance_type" {
  defaults = {
    supported_architectures = ["arm64"]
  }
}

mock_data "aws_ec2_managed_prefix_list" {
  defaults = {
    id = "pl-0123456789abcdef0"
  }
}

mock_data "aws_vpc" {
  defaults = {
    id         = "vpc-0123456789abcdef0"
    cidr_block = "10.9.0.0/16"
  }
}

# On apply the provider still checks that these look like ARNs.
mock_resource "aws_lb" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/mock/0123456789abcdef"
  }
}

mock_resource "aws_lb_listener" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/mock/0123456789abcdef/0123456789abcdef"
  }
}

mock_resource "aws_lb_target_group" {
  defaults = {
    arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/mock/0123456789abcdef"
  }
}

mock_resource "aws_cloudfront_key_value_store" {
  defaults = {
    arn = "arn:aws:cloudfront::123456789012:key-value-store/example-store"
  }
}

mock_resource "aws_cloudfront_function" {
  defaults = {
    arn = "arn:aws:cloudfront::123456789012:function/mock-password-gate"
  }
}
