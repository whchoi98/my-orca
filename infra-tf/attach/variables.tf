variable "region" {
  description = "AWS region of the host."
  type        = string
  default     = "ap-northeast-2"
}

variable "name" {
  description = "Deployment name, used as a prefix for every resource name."
  type        = string
  default     = "orca-on-vscode"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name))
    error_message = "name must be 2 to 24 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "host_instance_id" {
  description = "EC2 instance Orca is installed on. It must be online in SSM."
  type        = string

  validation {
    condition     = can(regex("^i-[0-9a-f]+$", var.host_instance_id))
    error_message = "host_instance_id must look like i-0123456789abcdef0."
  }
}

variable "host_listener_arn" {
  description = "HTTP:80 listener of the ALB in front of the host. Orca's rules are added to it."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:elasticloadbalancing:.+:listener/app/", var.host_listener_arn))
    error_message = "host_listener_arn must be the ARN of an Application Load Balancer listener."
  }
}

variable "host_instance_security_group_id" {
  description = "Security group of the host that gets the inbound rules from the ALB. Required when the host has more than one."
  type        = string
  default     = null
}

variable "host_alb_security_group_id" {
  description = "Security group of the ALB, the source of the inbound rules. Required when the ALB has more than one."
  type        = string
  default     = null
}

variable "host_user" {
  description = "Account orca-serve runs as on the host."
  type        = string
  default     = "ec2-user"
}

variable "host_label" {
  description = "Name of the host for tags and outputs, e.g. the CloudFormation stack that created it. Defaults to the instance ID."
  type        = string
  default     = ""
}

variable "orca_version" {
  description = "Orca release to install (github.com/stablyai/orca/releases, without the leading v). Changing it upgrades the host in place."
  type        = string
  default     = "1.4.269"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.orca_version))
    error_message = "orca_version must look like 1.4.269."
  }
}

variable "password_gate" {
  description = "Create the CloudFront Function password gate in front of Orca."
  type        = bool
  default     = true
}

variable "gate_setup_rule_priority" {
  description = "Listener rule priority of the /__gate/setup rule. Another service may already use lower ones on the shared listener."
  type        = number
  default     = 5
}

variable "orca_rule_priority" {
  description = "Listener rule priority of the Orca rule. Must be higher than gate_setup_rule_priority."
  type        = number
  default     = 10
}
