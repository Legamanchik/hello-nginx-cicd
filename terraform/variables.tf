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

variable "github_repo" {
  description = "GitHub repository (owner/name) allowed to deploy through OIDC"
  type        = string
  default     = "Legamanchik/hello-nginx-cicd"
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

# --- Kubernetes node (k3s + Argo CD) ---------------------------------------

variable "enable_k8s" {
  description = "Create the second server with k3s and Argo CD"
  type        = bool
  default     = true
}

variable "k8s_instance_type" {
  description = "EC2 type for the k3s node. c7i-flex.large (4 GB) runs k3s + Argo CD + the monitoring stack; t3.small (2 GB) is enough without monitoring"
  type        = string
  default     = "c7i-flex.large"
}

variable "k3s_version" {
  description = "k3s release (must be in Argo CD's tested Kubernetes versions)"
  type        = string
  default     = "v1.36.6+k3s1"
}

variable "argocd_version" {
  description = "Argo CD release tag"
  type        = string
  default     = "v3.5.7"
}

variable "argocd_nodeport" {
  description = "NodePort for the Argo CD UI (HTTPS)"
  type        = number
  default     = 30443
}

variable "grafana_nodeport" {
  description = "NodePort for Grafana"
  type        = number
  default     = 30300
}

variable "admin_password" {
  description = "Password for the Argo CD 'admin' and Grafana 'admin' users (set it in terraform.tfvars, never in git). No single quotes."
  type        = string
  sensitive   = true
}

variable "telegram_bot_token" {
  description = "Optional: Telegram bot token for alert notifications (from @BotFather). Can also be set later with scripts/set-telegram.sh"
  type        = string
  default     = ""
  sensitive   = true
}

variable "telegram_chat_id" {
  description = "Optional: Telegram chat ID that receives the alerts"
  type        = string
  default     = ""
}

variable "admin_cidrs" {
  description = "Your IP(s) in CIDR form, e.g. [\"203.0.113.10/32\"]: allowed to reach SSH, the Kubernetes API, Argo CD and Grafana on the k3s node"
  type        = list(string)
  default     = []
}
