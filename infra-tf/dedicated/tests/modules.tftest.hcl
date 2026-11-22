# The two modules both deployments share (../modules/front-door, ../modules/routes), against a
# mock AWS provider. They are tested here because terraform test runs from a root module.

mock_provider "aws" {
  source = "./tests/mocks"
}

run "routes_with_the_gate" {
  command = plan

  module {
    source = "../modules/routes"
  }

  variables {
    name                = "orca-test"
    vpc_id              = "vpc-0123456789abcdef0"
    listener_arn        = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/mock/0123456789abcdef/0123456789abcdef"
    instance_id         = "i-0123456789abcdef0"
    origin_secret_value = "header-value-for-the-test"
    gate_enabled        = true
  }

  assert {
    condition     = aws_lb_listener_rule.gate_setup[0].priority == 5 && aws_lb_listener_rule.orca.priority == 10
    error_message = "Default priorities are 5 (/__gate/setup) and 10 (Orca), the setup rule first."
  }
  assert {
    condition     = aws_lb_target_group.orca.port == 6768 && aws_lb_target_group.orca.health_check[0].path == "/web-index.html" && aws_lb_target_group.orca.health_check[0].port == "6768"
    error_message = "The Orca target group is on 6768 with the web client health check."
  }
  assert {
    condition     = aws_lb_target_group.gate_setup[0].port == 6769 && aws_lb_target_group.gate_setup[0].health_check[0].path == "/__gate/health"
    error_message = "The setup target group is on 6769 with /__gate/health."
  }
  assert {
    condition     = aws_lb_target_group_attachment.orca.port == 6768 && aws_lb_target_group_attachment.gate_setup[0].port == 6769 && aws_lb_target_group_attachment.orca.target_id == "i-0123456789abcdef0"
    error_message = "Both target groups point at the host."
  }
  assert {
    condition = length(aws_lb_listener_rule.orca.condition) == 1 && alltrue([
      for c in aws_lb_listener_rule.orca.condition :
      c.http_header[0].http_header_name == "X-Custom-Secret" && nonsensitive(tolist(c.http_header[0].values)[0]) == "header-value-for-the-test"
    ])
    error_message = "The Orca rule forwards only when X-Custom-Secret matches."
  }
  assert {
    condition = length(aws_lb_listener_rule.gate_setup[0].condition) == 2 && anytrue([
      for c in aws_lb_listener_rule.gate_setup[0].condition :
      length(c.http_header) == 1 && try(c.http_header[0].http_header_name, "") == "X-Custom-Secret"
      ]) && anytrue([
      for c in aws_lb_listener_rule.gate_setup[0].condition :
      length(c.path_pattern) == 1 && try(contains(c.path_pattern[0].values, "/__gate/setup"), false)
    ])
    error_message = "The setup rule needs both the header and the /__gate/setup path."
  }
  assert {
    condition     = aws_lb_listener_rule.orca.action[0].type == "forward" && aws_lb_listener_rule.gate_setup[0].action[0].type == "forward"
    error_message = "Both rules forward."
  }
}

run "routes_without_the_gate" {
  command = plan

  module {
    source = "../modules/routes"
  }

  variables {
    name                = "orca-test"
    vpc_id              = "vpc-0123456789abcdef0"
    listener_arn        = "arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:listener/app/mock/0123456789abcdef/0123456789abcdef"
    instance_id         = "i-0123456789abcdef0"
    origin_secret_value = "header-value-for-the-test"
    gate_enabled        = false
    orca_priority       = 40
  }

  assert {
    condition     = length(aws_lb_listener_rule.gate_setup) == 0 && length(aws_lb_target_group.gate_setup) == 0 && length(aws_lb_target_group_attachment.gate_setup) == 0
    error_message = "Without the gate there is no setup rule or target group."
  }
  assert {
    condition     = aws_lb_listener_rule.orca.priority == 40
    error_message = "The Orca rule priority can be moved on a shared listener."
  }
}

run "front_door_with_the_gate" {
  command = apply

  module {
    source = "../modules/front-door"
  }

  variables {
    name         = "orca-test"
    alb_dns_name = "mock-alb.example.test"
  }

  assert {
    condition     = can(regex("^[A-Za-z0-9]{48}$", nonsensitive(random_password.origin.result)))
    error_message = "The header value is 48 letters and digits."
  }
  assert {
    condition = alltrue([
      for o in aws_cloudfront_distribution.this.origin :
      o.domain_name == "mock-alb.example.test"
      && o.custom_origin_config[0].origin_protocol_policy == "http-only"
      && o.custom_origin_config[0].http_port == 80
      && o.custom_origin_config[0].origin_read_timeout == 60
    ]) && length(aws_cloudfront_distribution.this.origin) == 1
    error_message = "The one origin is the ALB over HTTP:80 with a 60 s read timeout."
  }
  assert {
    condition = alltrue(flatten([
      for o in aws_cloudfront_distribution.this.origin : [
        for h in o.custom_header :
        h.name == "X-Custom-Secret" && nonsensitive(h.value) == nonsensitive(random_password.origin.result)
      ]
    ])) && length(flatten([for o in aws_cloudfront_distribution.this.origin : [for h in o.custom_header : h.name]])) == 1
    error_message = "The origin request carries X-Custom-Secret with the generated value."
  }
  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https" && length(aws_cloudfront_distribution.this.default_cache_behavior[0].allowed_methods) == 7
    error_message = "The default behavior redirects to HTTPS and allows every method (WebSocket, POST)."
  }
  assert {
    condition = alltrue([
      for f in aws_cloudfront_distribution.this.default_cache_behavior[0].function_association :
      f.event_type == "viewer-request" && f.function_arn == aws_cloudfront_function.gate[0].arn
    ]) && length(aws_cloudfront_distribution.this.default_cache_behavior[0].function_association) == 1
    error_message = "The gate runs on viewer requests of the default behavior."
  }
  assert {
    condition = aws_cloudfront_distribution.this.ordered_cache_behavior[0].path_pattern == "/assets/*" && alltrue([
      for f in aws_cloudfront_distribution.this.ordered_cache_behavior[0].function_association :
      f.event_type == "viewer-request" && f.function_arn == aws_cloudfront_function.gate[0].arn
    ]) && length(aws_cloudfront_distribution.this.ordered_cache_behavior[0].function_association) == 1
    error_message = "The gate also runs in front of the cached /assets/* behavior."
  }
  assert {
    condition     = aws_cloudfront_function.gate[0].runtime == "cloudfront-js-2.0" && aws_cloudfront_function.gate[0].publish && length(aws_cloudfront_function.gate[0].key_value_store_associations) == 1
    error_message = "The gate function is JavaScript runtime 2.0, published, with the one store."
  }
  assert {
    condition     = aws_cloudfront_function.gate[0].code == file("../../infra-cdk/lib/functions/password-gate.js")
    error_message = "The gate function is the file the CDK stacks ship."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.gate[0].block_public_acls && aws_s3_bucket_public_access_block.gate[0].block_public_policy && aws_s3_bucket_public_access_block.gate[0].ignore_public_acls && aws_s3_bucket_public_access_block.gate[0].restrict_public_buckets
    error_message = "The bundle bucket blocks public access."
  }
  assert {
    condition     = can(regex("^gate/[0-9a-f]{64}\\.zip$", aws_s3_object.gate[0].key)) && output.gate_bundle_url == "s3://${aws_s3_bucket.gate[0].id}/${aws_s3_object.gate[0].key}"
    error_message = "The bundle key carries the content hash, so a changed bundle gets a new URL."
  }
  assert {
    condition     = aws_secretsmanager_secret_version.origin.secret_string == random_password.origin.result
    error_message = "Secrets Manager holds the same header value."
  }
  assert {
    condition     = output.gate_enabled && output.gate_kvs_arn == aws_cloudfront_key_value_store.gate[0].arn && output.gate_host_policy_json != null
    error_message = "Gate outputs are filled in."
  }
}

run "front_door_without_the_gate" {
  command = plan

  module {
    source = "../modules/front-door"
  }

  variables {
    name          = "orca-test-nogate"
    alb_dns_name  = "mock-alb.example.test"
    password_gate = false
  }

  assert {
    condition     = length(aws_cloudfront_key_value_store.gate) == 0 && length(aws_cloudfront_function.gate) == 0 && length(aws_s3_bucket.gate) == 0 && length(aws_s3_object.gate) == 0
    error_message = "Without the gate there is no store, function or bundle."
  }
  assert {
    condition     = length(aws_cloudfront_distribution.this.default_cache_behavior[0].function_association) == 0 && length(aws_cloudfront_distribution.this.ordered_cache_behavior[0].function_association) == 0
    error_message = "Without the gate no function is associated."
  }
  assert {
    condition     = output.gate_kvs_arn == "" && output.gate_bundle_url == "" && output.gate_host_policy_json == null && !output.gate_enabled
    error_message = "Without the gate the gate outputs are empty."
  }
}
