terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

# -----------------------------------------------------------------------------
# Service Accounts
# -----------------------------------------------------------------------------

resource "google_service_account" "app_sa" {
  account_id   = "app-prod-api-server"
  display_name = "App API Server (prod)"
  description  = "Service account for the production API server — least-privilege GCS and Pub/Sub access"
  project      = var.project_id
}

# Bind at resource level, not project level
resource "google_storage_bucket_iam_member" "app_sa_gcs_reader" {
  bucket = var.app_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.app_sa.email}"
}

resource "google_pubsub_topic_iam_member" "app_sa_pubsub_publisher" {
  topic  = var.pubsub_topic
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.app_sa.email}"
}

# -----------------------------------------------------------------------------
# Workload Identity Federation — GitHub Actions
# -----------------------------------------------------------------------------

resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "WIF pool for GitHub Actions CI/CD pipelines"
  project                   = var.project_id
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  project                            = var.project_id
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
    "attribute.workflow"   = "assertion.workflow"
  }

  # Restrict to specific org AND specific repo for deploy workflows
  attribute_condition = "assertion.repository == '${var.github_repo}' && assertion.ref == 'refs/heads/main'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow the GitHub Actions principal to impersonate the deploy SA
resource "google_service_account_iam_binding" "github_wif_impersonation" {
  service_account_id = google_service_account.app_sa.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.github_repo}"
  ]
}

# -----------------------------------------------------------------------------
# GKE Workload Identity
# -----------------------------------------------------------------------------

resource "google_service_account" "gke_app_sa" {
  account_id   = "gke-app-prod"
  display_name = "GKE App (prod)"
  description  = "Service account for the Kubernetes app deployment in prod"
  project      = var.project_id
}

resource "google_service_account_iam_binding" "gke_workload_identity" {
  service_account_id = google_service_account.gke_app_sa.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/${var.k8s_service_account}]"
  ]
}

# -----------------------------------------------------------------------------
# Org Policy — disable SA key creation org-wide
# (Apply this resource at org level, not project level)
# -----------------------------------------------------------------------------

resource "google_org_policy_policy" "disable_sa_key_creation" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = true
    }
  }
}

resource "google_org_policy_policy" "disable_sa_key_upload" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyUpload"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = true
    }
  }
}

# -----------------------------------------------------------------------------
# Audit logging — enable Data Read/Write for all services
# -----------------------------------------------------------------------------

resource "google_project_iam_audit_config" "all_services" {
  project = var.project_id
  service = "allServices"

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
