variable "name" {
  description = "Deployment name, used as a prefix for the target group names (at most 24 characters)."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the ALB and the orca-serve host."
  type        = string
}

variable "listener_arn" {
  description = "HTTP:80 listener the rules are added to."
  type        = string
}

variable "instance_id" {
  description = "EC2 instance running orca-serve."
  type        = string
}

variable "origin_secret_value" {
  description = "X-Custom-Secret header value the rules match."
  type        = string
  sensitive   = true
}

variable "gate_enabled" {
  description = "Add the /__gate/setup rule and target group for the first-login setup service."
  type        = bool
}

variable "gate_setup_priority" {
  description = "Listener rule priority of the /__gate/setup rule. Must be lower than orca_priority."
  type        = number
  default     = 5
}

variable "orca_priority" {
  description = "Listener rule priority of the Orca rule."
  type        = number
  default     = 10
}
