# The header secret itself is never output. The pairing link is not an output either: it would
# sit in the state file in plain text. Read it with get_pairing_url.sh --tf dedicated.

output "region" {
  description = "AWS region of the deployment."
  value       = var.region
}

output "name" {
  description = "Deployment name."
  value       = var.name
}

output "orca_version" {
  description = "Orca release installed at first boot."
  value       = var.orca_version
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
  description = "Orca server EC2 instance ID."
  value       = aws_instance.orca.id
}

output "private_ip" {
  description = "Orca server private IP."
  value       = aws_instance.orca.private_ip
}

output "vpc_id" {
  description = "VPC ID."
  value       = local.vpc_id
}

output "alb_endpoint" {
  description = "Public ALB DNS name (CloudFront prefix list only; direct access blocked)."
  value       = "http://${aws_lb.this.dns_name}"
}

output "ec2_role_name" {
  description = "Orca server EC2 IAM role name."
  value       = aws_iam_role.orca.name
}

output "origin_secret_arn" {
  description = "Secrets Manager ARN of the X-Custom-Secret header value."
  value       = module.front_door.origin_secret_arn
}

output "password_gate_store_arn" {
  description = "CloudFront KeyValueStore ARN for the password gate (set with set_password.sh --tf dedicated); empty when the gate is off."
  value       = module.front_door.gate_kvs_arn
}

output "password_gate_setup_bundle" {
  description = "First-login setup service bundle (reinstall: unzip, then install.sh <kvs-arn> <region>); empty when the gate is off."
  value       = module.front_door.gate_bundle_url
}

output "ssm_access" {
  description = "SSM Session Manager access command."
  value       = "aws ssm start-session --target ${aws_instance.orca.id} --region ${var.region}"
}
