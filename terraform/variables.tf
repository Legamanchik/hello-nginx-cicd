variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-north-1"
}

variable "project" {
  description = "Name prefix for all resources"
  type        = string
  default     = "hello-nginx"
}

variable "instance_type" {
  description = "EC2 type for the Docker test server (Free plan eligible)"
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root disk size, GiB"
  type        = number
  default     = 16
}

variable "ssh_public_key_path" {
  description = "Public key that CI and you use to SSH into the server"
  type        = string
  default     = "~/.ssh/hello-nginx-deploy.pub"
}

variable "ssh_allowed_cidrs" {
  description = "Who may reach port 22. GitHub-hosted runners use dynamic IPs, so the default is open; auth is key-only."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "budget_alert_email" {
  description = "If set, creates a monthly AWS Budget that emails this address at 80% of budget_limit_usd"
  type        = string
  default     = ""
}

variable "budget_limit_usd" {
  description = "Monthly budget limit in USD"
  type        = number
  default     = 30
}
