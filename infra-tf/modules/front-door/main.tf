# What both deployments put in front of an orca-serve host: the X-Custom-Secret value, the
# password gate (CloudFront Function + KeyValueStore + setup bundle) and the CloudFront
# distribution. Terraform counterpart of infra-cdk/lib/orca-front-door.ts; the function and the
# setup service are the same files the CDK stacks ship (infra-cdk/lib/functions, infra-cdk/lib/gate).

locals {
  cdk_lib            = "${path.module}/../../../infra-cdk/lib"
  gate_function_file = "${local.cdk_lib}/functions/password-gate.js"
  gate_source_dir    = "${local.cdk_lib}/gate"
  origin_id          = "orca-alb"
}

# -------------------------------------------------------
# Origin verification secret (X-Custom-Secret)
# -------------------------------------------------------
# The CloudFront prefix list admits every CloudFront distribution, not just this one, so this
# value is the only thing that ties the ALB to this distribution. Unlike the CDK stacks, where
# the value is a CloudFormation dynamic reference, Terraform keeps it in the state file.
resource "random_password" "origin" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "origin" {
  name_prefix             = "${var.name}-origin-verify-"
  description             = "${var.name} CloudFront -> ALB X-Custom-Secret header value"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "origin" {
  secret_id     = aws_secretsmanager_secret.origin.id
  secret_string = random_password.origin.result
}

# -------------------------------------------------------
# Password gate (CloudFront Function + KeyValueStore)
# -------------------------------------------------------
# The store holds only a salt, a salted hash and the cookie signing key, written by
# set_password.sh or by the host's first-login setup service. Functions can only read it.
resource "aws_cloudfront_key_value_store" "gate" {
  count   = var.password_gate ? 1 : 0
  name    = "${var.name}-gate"
  comment = "${var.name} Orca password gate (salt, hash, cookie key)"
}

resource "aws_cloudfront_function" "gate" {
  count   = var.password_gate ? 1 : 0
  name    = "${var.name}-password-gate"
  runtime = "cloudfront-js-2.0"
  comment = "${var.name} Orca password gate (viewer request)"
  publish = true
  code    = file(local.gate_function_file)

  key_value_store_associations = [aws_cloudfront_key_value_store.gate[0].arn]
}

# First-login setup service bundle (infra-cdk/lib/gate), fetched by the host with its own role.
# The object key carries the content hash: a changed bundle gets a new URL, which re-runs the
# install on an attached host.
data "archive_file" "gate" {
  count       = var.password_gate ? 1 : 0
  type        = "zip"
  source_dir  = local.gate_source_dir
  excludes    = ["__pycache__", "__pycache__/**", "**/*.pyc"]
  output_path = "${path.module}/.build/gate.zip"
  # Same hash whatever the umask of the machine that runs Terraform. The host runs install.sh
  # with bash and installs setup_service.py with its own mode, so the bits in the zip do not matter.
  output_file_mode = "0644"
}

resource "aws_s3_bucket" "gate" {
  count         = var.password_gate ? 1 : 0
  bucket_prefix = "${var.name}-gate-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "gate" {
  count                   = var.password_gate ? 1 : 0
  bucket                  = aws_s3_bucket.gate[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "gate_bucket" {
  count = var.password_gate ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.gate[0].arn, "${aws_s3_bucket.gate[0].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "gate" {
  count  = var.password_gate ? 1 : 0
  bucket = aws_s3_bucket.gate[0].id
  policy = data.aws_iam_policy_document.gate_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.gate]
}

resource "aws_s3_object" "gate" {
  count       = var.password_gate ? 1 : 0
  bucket      = aws_s3_bucket.gate[0].id
  key         = "gate/${data.archive_file.gate[0].output_sha256}.zip"
  source      = data.archive_file.gate[0].output_path
  source_hash = data.archive_file.gate[0].output_base64sha256
}

# What the host's role needs for the first-login setup service: read the bundle, read and
# write the store. Each deployment attaches this to its own (dedicated) or the host's role.
data "aws_iam_policy_document" "gate_host" {
  count = var.password_gate ? 1 : 0

  statement {
    sid = "PasswordGateFirstLoginSetup"
    actions = [
      "cloudfront-keyvaluestore:DescribeKeyValueStore",
      "cloudfront-keyvaluestore:GetKey",
      "cloudfront-keyvaluestore:UpdateKeys",
    ]
    resources = [aws_cloudfront_key_value_store.gate[0].arn]
  }

  statement {
    sid       = "PasswordGateSetupBundle"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.gate[0].arn}/gate/*"]
  }
}

# -------------------------------------------------------
# CloudFront in front of the ALB
# -------------------------------------------------------
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2"
  comment         = "Orca server distribution for ${var.name}"
  price_class     = "PriceClass_All"

  origin {
    origin_id   = local.origin_id
    domain_name = var.alb_dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60
    }

    # The origin request always carries the header; the ALB forwards only when it matches.
    custom_header {
      name  = "X-Custom-Secret"
      value = random_password.origin.result
    }
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # Pass WebSocket upgrade headers and ?orca-client=web through untouched.
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    dynamic "function_association" {
      for_each = aws_cloudfront_function.gate
      content {
        event_type   = "viewer-request"
        function_arn = function_association.value.arn
      }
    }
  }

  # Hashed, immutable web client bundles (Cache-Control: immutable from Orca).
  # The gate still runs first: viewer-request functions execute before the cache.
  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id

    dynamic "function_association" {
      for_each = aws_cloudfront_function.gate
      content {
        event_type   = "viewer-request"
        function_arn = function_association.value.arn
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
