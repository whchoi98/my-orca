variable "name" {
  description = "Deployment name, used as a prefix for every resource name."
  type        = string
}

variable "alb_dns_name" {
  description = "DNS name of the ALB CloudFront uses as its origin (HTTP:80)."
  type        = string
}

variable "password_gate" {
  description = "Create the CloudFront Function password gate in front of Orca."
  type        = bool
  default     = true
}
