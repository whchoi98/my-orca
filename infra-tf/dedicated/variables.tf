variable "region" {
  description = "AWS region of the deployment."
  type        = string
  default     = "ap-northeast-2"
}

variable "name" {
  description = "Deployment name, used as a prefix for every resource name."
  type        = string
  default     = "orca-server"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,23}$", var.name))
    error_message = "name must be 2 to 24 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the Orca server (ARM64 Graviton recommended). The AMI architecture follows it."
  type        = string
  default     = "r6g.xlarge"
}

variable "orca_version" {
  description = "Orca release installed at first boot (github.com/stablyai/orca/releases, without the leading v). Not applied to an existing instance."
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

variable "vpc_cidr" {
  description = "CIDR of the new VPC (ignored when vpc_id is set)."
  type        = string
  default     = "10.253.0.0/16"
}

variable "vpc_name" {
  description = "Name tag of the new VPC (ignored when vpc_id is set)."
  type        = string
  default     = "orca-vpc"
}

variable "vpc_id" {
  description = "Existing VPC to use instead of a new one. Requires alb_subnet_ids and instance_subnet_id."
  type        = string
  default     = null
}

variable "alb_subnet_ids" {
  description = "Public subnets (two or more Availability Zones) for the ALB, in the existing VPC."
  type        = list(string)
  default     = []
}

variable "instance_subnet_id" {
  description = "Private subnet with outbound internet access for the Orca server, in the existing VPC."
  type        = string
  default     = null
}

variable "create_ssm_endpoints" {
  description = "Create the SSM interface endpoints (ssm, ssmmessages, ec2messages). Turn off when the VPC already has them."
  type        = bool
  default     = true
}
