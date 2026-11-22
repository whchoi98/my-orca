# The host the mock AWS provider returns: one instance behind one ALB with an HTTP:80 listener,
# one security group each.

mock_data "aws_instance" {
  defaults = {
    vpc_security_group_ids = ["sg-0123456789abcdef0"]
    iam_instance_profile   = "host-profile"
  }
}

mock_data "aws_lb_listener" {
  defaults = {
    port              = 80
    protocol          = "HTTP"
    load_balancer_arn = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:loadbalancer/app/host/0123456789abcdef"
  }
}

mock_data "aws_lb" {
  defaults = {
    dns_name        = "host-alb.example.test"
    vpc_id          = "vpc-0123456789abcdef0"
    security_groups = ["sg-0123456789abcdef1"]
  }
}

mock_data "aws_iam_instance_profile" {
  defaults = {
    role_name = "host-role"
  }
}

mock_data "aws_iam_policy_document" {
  defaults = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}
