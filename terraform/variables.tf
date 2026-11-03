variable "cluster_name" {
  type        = string
  description = "EKS cluster name (also used to name the bastion and IAM roles)."
  default     = "academy-eks-demo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,39}$", var.cluster_name))
    error_message = "cluster_name must be 1-40 lowercase letters/digits/dashes, starting with a letter."
  }
}

variable "region" {
  type        = string
  description = "AWS region for the lab VPC, EKS cluster, and bastion."
  default     = "us-east-2"
}

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version."
  default     = "1.35"
}

variable "admin_cidr" {
  type        = string
  description = "Public IPv4 /32 allowed to reach the EKS public API endpoint."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR. Two public subnets are carved from this; there is no NAT gateway."
  default     = "10.0.0.0/16"
}

variable "desired_size" {
  type        = number
  description = "On-Demand worker count (1 or 2). Use scale-workers.sh; do not edit by hand during class."
  default     = 1

  validation {
    condition     = contains([1, 2], var.desired_size)
    error_message = "desired_size must be 1 or 2."
  }
}

variable "cost_tag_key" {
  type        = string
  description = "Cost allocation tag key. Activate this key in AWS Billing."
  default     = "env"
}

variable "cost_tag_value" {
  type        = string
  description = "Cost allocation tag value used to filter Cost Explorer after the demo."
  default     = "test-eks"
}
