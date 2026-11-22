output "orca_port" {
  description = "Port orca-serve listens on."
  value       = local.orca_port
}

output "gate_setup_port" {
  description = "Port the first-login setup service listens on."
  value       = local.gate_setup_port
}

output "orca_target_group_arn" {
  description = "Target group of orca-serve."
  value       = aws_lb_target_group.orca.arn
}
