variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "app" {
  type        = string
  default     = "shop"
  description = "Short app name, used as a resource prefix (lowercase, <= 8 chars)."
}

variable "env" {
  type        = string
  default     = "prod"
  description = "Environment name. 'prod' enables HA, deletion protection and min instances."
}

variable "domain" {
  type        = string
  description = "Public FQDN served by the load balancer, e.g. app.example.com."
}

variable "github_repo" {
  type        = string
  description = "GitHub repo allowed to deploy via Workload Identity Federation, as owner/name."
}

variable "alert_email" {
  type        = string
  description = "Email address for monitoring alerts."
}

variable "db_tier" {
  type    = string
  default = "db-custom-2-7680"
}

variable "armor_rate_limit_per_minute" {
  type        = number
  default     = 300
  description = "Per-IP request limit enforced by Cloud Armor."
}

variable "bootstrap_image" {
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
  description = "Placeholder image for first apply. CI/CD replaces it; Terraform ignores image drift."
}

variable "email_from" {
  type        = string
  default     = "orders@example.com"
  description = "Verified sender address for order emails."
}

variable "shop_name" {
  type    = string
  default = "My Shop"
}
