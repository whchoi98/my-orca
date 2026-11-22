# The header secret itself is never output. The pairing link is not an output either: it would
# sit in the state file in plain text. Read it with get_pairing_url.sh --tf attach.

output "region" {
  description = "AWS region of the deployment."
  value       = var.region
}

output "name" {
  description = "Deployment name."
  value       = var.name
}

output "host" {
  description = "Server Orca runs on (not modified; terraform destroy only removes Orca)."
  value       = local.host_label
}

output "orca_version" {
  description = "Orca release installed on the host."
  value       = var.orca_version

  depends_on = [terraform_data.host_install]
}

output "cloudfront_url" {
  description = "CloudFront URL (Orca web client; pair with the link from get_pairing_url.sh)."
  value       = "https://${module.front_door.domain_name}"
}

output "pairing_address" {
  description = "Address Orca embeds in pairing links."
  value       = local.pairing_address
}

output "instance_id" {
  description = "Host EC2 instance running orca-serve."
  value       = var.host_instance_id
}

output "alb_endpoint" {
  description = "Host ALB (shared; reachable only through CloudFront when its security group allows only the prefix list)."
  value       = "http://${data.aws_lb.host.dns_name}"
}

output "origin_secret_arn" {
  description = "Secrets Manager ARN of the X-Custom-Secret header value (Orca distribution only)."
  value       = module.front_door.origin_secret_arn
}

output "password_gate_store_arn" {
  description = "CloudFront KeyValueStore ARN for the password gate (set with set_password.sh --tf attach); empty when the gate is off."
  value       = module.front_door.gate_kvs_arn
}

output "password_gate_setup_bundle" {
  description = "First-login setup service bundle (reinstall: unzip, then install.sh <kvs-arn> <region>); empty when the gate is off."
  value       = module.front_door.gate_bundle_url
}

output "ssm_access" {
  description = "SSM Session Manager access command."
  value       = "aws ssm start-session --target ${var.host_instance_id} --region ${var.region}"
}
