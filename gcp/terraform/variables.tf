variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "org_id" {
  type        = string
  description = "GCP organization ID (numeric)"
}

variable "app_bucket" {
  type        = string
  description = "GCS bucket name for app storage (without gs:// prefix)"
}

variable "pubsub_topic" {
  type        = string
  description = "Pub/Sub topic ID"
}

variable "github_repo" {
  type        = string
  description = "GitHub repository in 'org/repo' format"
}

variable "k8s_namespace" {
  type        = string
  description = "Kubernetes namespace for GKE workload identity binding"
  default     = "default"
}

variable "k8s_service_account" {
  type        = string
  description = "Kubernetes service account name for GKE workload identity binding"
}
