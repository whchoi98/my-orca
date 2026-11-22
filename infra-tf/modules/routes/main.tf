# Target groups and listener rules on the ALB: forward only when X-Custom-Secret matches.
# Terraform counterpart of addOrcaRoutes in infra-cdk/lib/orca-front-door.ts.

locals {
  # orca-ide serve answers the web client (HTTP) and its RPC (WebSocket) on this one port.
  orca_port = 6768
  # First-login password setup service (infra-cdk/lib/gate/setup_service.py), reached via /__gate/setup.
  gate_setup_port = 6769
}

resource "aws_lb_target_group" "orca" {
  name        = "${var.name}-tg"
  vpc_id      = var.vpc_id
  port        = local.orca_port
  protocol    = "HTTP"
  target_type = "instance"

  health_check {
    # Served by Orca's static web client handler without authentication.
    path                = "/web-index.html"
    port                = tostring(local.orca_port)
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "orca" {
  target_group_arn = aws_lb_target_group.orca.arn
  target_id        = var.instance_id
  port             = local.orca_port
}

resource "aws_lb_target_group" "gate_setup" {
  count       = var.gate_enabled ? 1 : 0
  name        = "${var.name}-gate-tg"
  vpc_id      = var.vpc_id
  port        = local.gate_setup_port
  protocol    = "HTTP"
  target_type = "instance"

  health_check {
    path                = "/__gate/health"
    port                = tostring(local.gate_setup_port)
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "gate_setup" {
  count            = var.gate_enabled ? 1 : 0
  target_group_arn = aws_lb_target_group.gate_setup[0].arn
  target_id        = var.instance_id
  port             = local.gate_setup_port
}

# Evaluated before the Orca rule; the CloudFront Function forwards this path only while no
# access password is set.
resource "aws_lb_listener_rule" "gate_setup" {
  count        = var.gate_enabled ? 1 : 0
  listener_arn = var.listener_arn
  priority     = var.gate_setup_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gate_setup[0].arn
  }

  condition {
    http_header {
      http_header_name = "X-Custom-Secret"
      values           = [var.origin_secret_value]
    }
  }

  condition {
    path_pattern {
      values = ["/__gate/setup"]
    }
  }
}

resource "aws_lb_listener_rule" "orca" {
  listener_arn = var.listener_arn
  priority     = var.orca_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.orca.arn
  }

  condition {
    http_header {
      http_header_name = "X-Custom-Secret"
      values           = [var.origin_secret_value]
    }
  }
}
