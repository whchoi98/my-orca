output "domain_name" {
  description = "CloudFront domain name of the Orca distribution."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "origin_secret_value" {
  description = "X-Custom-Secret header value, for the ALB listener rules."
  value       = random_password.origin.result
  sensitive   = true
}

output "origin_secret_arn" {
  description = "Secrets Manager ARN of the X-Custom-Secret header value."
  value       = aws_secretsmanager_secret.origin.arn
}

output "gate_enabled" {
  description = "Whether the password gate exists."
  value       = var.password_gate
}

output "gate_kvs_arn" {
  description = "Password gate KeyValueStore ARN; empty when the gate is off."
  value       = var.password_gate ? aws_cloudfront_key_value_store.gate[0].arn : ""
}

output "gate_bundle_url" {
  description = "s3:// URL of the first-login setup service bundle; empty when the gate is off."
  value       = var.password_gate ? "s3://${aws_s3_bucket.gate[0].id}/${aws_s3_object.gate[0].key}" : ""
}

output "gate_host_policy_json" {
  description = "IAM policy the host's role needs for the setup service; null when the gate is off."
  value       = one(data.aws_iam_policy_document.gate_host[*].json)
}
