variable "project_name" {
  type        = string
  description = "Prefix for resource names"
  default     = "static-site"
}

variable "aws_region" {
  type        = string
  description = "Primary region for S3, Route 53 (global), Budgets, etc."
  default     = "us-east-1"
}

variable "domain_name" {
  type        = string
  description = "FQDN for your site (e.g., www.example.com). Leave empty to skip DNS + cert."
  default     = ""
}

variable "hosted_zone_id" {
  type        = string
  description = "Route 53 hosted zone ID for the root domain (required if domain_name is set)."
  default     = ""
}

variable "enable_waf" {
  type        = bool
  description = "Attach a basic AWS Managed Rules WAF to CloudFront."
  default     = true
}

variable "enable_logging" {
  type        = bool
  description = "Enable CloudFront + S3 access logging."
  default     = true
}

variable "monthly_budget_usd" {
  type        = number
  description = "Create an AWS Budget to alert if monthly cost exceeds this value. Set 0 to disable."
  default     = 10
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags to apply to resources."
}
