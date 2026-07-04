# GCP IAM Deep-Dive: Service Accounts, WIF, and Org Policies

**Audience:** Engineers who need to get GCP IAM right in production. Assumes familiarity with IAM concepts but not GCP specifics.

**Last updated:** 2026-07-04

---

## The Mental Model

GCP IAM has three identity types you need to understand:

1. **User accounts** — humans, authenticated by Google Identity or a federated IdP
2. **Service accounts** — machine identities, scoped to a GCP project
3. **Workload Identity Federation principals** — external identities (AWS IAM roles, Azure managed identities, GitHub Actions, etc.) mapped into GCP without a service account key

The historic approach was to give every workload a service account key (a long-lived JSON credential) and copy it into CI/CD systems, VMs, and containers. This is wrong. Key leakage is the single most common GCP identity incident. WIF eliminates this entire class of risk.

**The rule:** Never create or download a service account key unless you have no alternative. WIF covers AWS, Azure, GitHub Actions, GitLab, Kubernetes, and any OIDC-compliant system. If you think you need a key, check WIF first.

---

## Service Account Best Practices

### Least-Privilege Binding

Service accounts are not principals in isolation — they acquire permissions via IAM bindings. The scope of those bindings matters enormously.

**Wrong:** Bind at project level with `roles/editor`
```bash
# Don't do this
gcloud projects add-iam-policy-binding my-project \
  --member="serviceAccount:my-sa@my-project.iam.gserviceaccount.com" \
  --role="roles/editor"
```

**Right:** Bind at resource level with the minimum role
```bash
# Bind only to the specific bucket this SA needs
gcloud storage buckets add-iam-policy-binding gs://my-bucket \
  --member="serviceAccount:my-sa@my-project.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer"
```

Common mistake: granting `roles/iam.serviceAccountUser` at the project level. This lets the grantee impersonate *any* service account in the project. Bind it on the specific service account resource instead.

### Service Account Impersonation Chains

Impersonation (`roles/iam.serviceAccountTokenCreator`) lets one identity generate tokens for another. Use this to:
- Let a developer test with a service account without downloading keys
- Build multi-hop authorization flows (SA-A → SA-B → SA-C)
- Grant short-lived access for debugging

```bash
# Grant impersonation on a specific SA, not project-wide
gcloud iam service-accounts add-iam-policy-binding target-sa@project.iam.gserviceaccount.com \
  --member="serviceAccount:caller-sa@project.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator"
```

Keep chains short. A chain of A→B→C→D is auditing and debugging hell. If you need more than two hops, redesign the architecture.

### Key Rotation — and Why You Should Eliminate Keys Instead

If you must use a service account key:
- Rotate every 90 days maximum (30 days for sensitive workloads)
- Use Secret Manager to store keys, not environment variables or config files
- Audit key usage via Cloud Audit Logs (look for `google.iam.admin.v1.GetServiceAccountKey`)
- Delete keys immediately when a workload is decommissioned

But again: **eliminate the key entirely**. Use WIF for external workloads, use the metadata server for GCE/GKE, use Application Default Credentials for local dev with `gcloud auth application-default login`.

### Service Account Naming Conventions

GCP service account IDs are permanent and visible in audit logs. Use a consistent naming scheme:

```
{workload}-{environment}-{function}@{project}.iam.gserviceaccount.com

Examples:
api-server-prod-gcs-reader@myproject.iam.gserviceaccount.com
batch-job-staging-bq-writer@myproject.iam.gserviceaccount.com
```

One service account per workload function, not per environment when the project differs per environment.

---

## Workload Identity Federation

WIF lets external identities exchange their native token for a GCP credential without a service account key. The flow:

```
External Workload
    │
    │ 1. Present native credential
    │    (AWS SigV4, Azure OIDC token, GitHub Actions JWT, etc.)
    ▼
Security Token Service (STS)
    │
    │ 2. Validate token against WIF pool/provider rules
    │ 3. Issue short-lived GCP federated token
    ▼
IAM (optional: token exchange for SA token)
    │
    │ 4. If SA impersonation configured, issue SA access token
    ▼
GCP API
```

### WIF Pool and Provider Configuration

A **pool** groups a set of external identity sources. A **provider** within a pool defines one external IdP.

```hcl
# Terraform: WIF pool and GitHub Actions provider
resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "WIF pool for GitHub Actions CI/CD"
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
  }

  # Only allow tokens from specific repositories
  attribute_condition = "assertion.repository_owner == 'my-org'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}
```

### Attribute Mapping and Conditions — Get These Right

Attribute mapping translates claims from the external token into GCP attributes. Conditions restrict which external identities can use the provider.

**Always set an `attribute_condition`.** Without one, any token from the configured issuer can authenticate. For GitHub Actions, an unguarded provider accepts tokens from *any* GitHub repository.

Common mistakes in attribute conditions:

```hcl
# WRONG: Only checks org, any repo in org can authenticate
attribute_condition = "assertion.repository_owner == 'my-org'"

# BETTER: Lock to specific repository and branch
attribute_condition = "assertion.repository == 'my-org/my-repo' && assertion.ref == 'refs/heads/main'"

# BEST for prod deployments: Also check workflow file
attribute_condition = "assertion.repository == 'my-org/my-repo' && assertion.ref == 'refs/heads/main' && assertion.workflow == 'Deploy'"
```

### IAM Binding for WIF Principals

Bind permissions to the WIF principal (not a service account) when the external workload can call GCP APIs directly:

```bash
# Principal format: principalSet://iam.googleapis.com/projects/{number}/locations/global/workloadIdentityPools/{pool}/attribute.{key}/{value}
gcloud storage buckets add-iam-policy-binding gs://my-bucket \
  --member="principalSet://iam.googleapis.com/projects/123456/locations/global/workloadIdentityPools/github-actions/attribute.repository/my-org/my-repo" \
  --role="roles/storage.objectCreator"
```

Or use service account impersonation (required when the workload needs to call APIs that don't support WIF direct binding yet):

```bash
gcloud iam service-accounts add-iam-policy-binding deployer-sa@my-project.iam.gserviceaccount.com \
  --member="principalSet://iam.googleapis.com/projects/123456/locations/global/workloadIdentityPools/github-actions/attribute.repository/my-org/my-repo" \
  --role="roles/iam.workloadIdentityUser"
```

### WIF for Kubernetes (Workload Identity)

GKE has a first-class integration that maps Kubernetes service accounts to GCP service accounts:

```hcl
resource "google_service_account_iam_binding" "workload_identity" {
  service_account_id = google_service_account.app_sa.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${var.ksa_name}]"
  ]
}
```

```bash
# Annotate the Kubernetes service account
kubectl annotate serviceaccount my-ksa \
  --namespace my-namespace \
  iam.gke.io/gcp-service-account=my-sa@my-project.iam.gserviceaccount.com
```

---

## Org Policies for IAM Hardening

Org policies are resource hierarchy constraints that override project-level IAM. They're the mechanism for enforcing baseline security standards across your org.

### Key Constraints to Enforce

**Disable service account key creation:**
```hcl
resource "google_org_policy_policy" "disable_sa_key_creation" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyCreation"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = true
    }
  }
}
```

This is the single most impactful org policy for IAM security. With this enabled, no one can create new service account keys anywhere in the org. Exceptions require an org policy override at the project level, which is auditable.

**Disable service account key upload:**
```hcl
resource "google_org_policy_policy" "disable_sa_key_upload" {
  name   = "organizations/${var.org_id}/policies/iam.disableServiceAccountKeyUpload"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = true
    }
  }
}
```

**Restrict Workload Identity Pool providers:**
```hcl
resource "google_org_policy_policy" "wif_provider_allowlist" {
  name   = "organizations/${var.org_id}/policies/iam.workloadIdentityPoolProviders"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      values {
        allowed_values = [
          "https://token.actions.githubusercontent.com",
          "https://accounts.google.com",
        ]
      }
    }
  }
}
```

This prevents teams from creating WIF providers that accept tokens from arbitrary issuers.

**Restrict domain membership:**
```hcl
resource "google_org_policy_policy" "domain_restriction" {
  name   = "organizations/${var.org_id}/policies/iam.allowedPolicyMemberDomains"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      values {
        allowed_values = [
          "principalSet://iam.googleapis.com/organizations/${var.org_id}",
          "C0xxxxxxx",  # Your Google Workspace customer ID
        ]
      }
    }
  }
}
```

**Warning:** This constraint breaks allUsers/allAuthenticatedUsers bindings, which you almost certainly want. It also prevents cross-org sharing by default, requiring explicit exceptions. Roll it out carefully with an exceptions process.

### Org Policy Inheritance

Org policies cascade down: org → folder → project. Lower levels can override (if the constraint allows override) or the org level can enforce with `reset: true` (allows) or specific values.

Use folders to group projects with similar security posture. Don't fight inheritance by setting exceptions at the project level for standard workloads — fix the folder structure.

---

## IAM Conditions

IAM Conditions add attribute-based access control on top of standard role bindings. Conditions are CEL (Common Expression Language) expressions evaluated at authorization time.

### Useful Condition Patterns

**Time-bound access (break-glass):**
```hcl
resource "google_project_iam_member" "break_glass" {
  project = var.project_id
  role    = "roles/editor"
  member  = "user:oncall@mycompany.com"

  condition {
    title       = "break-glass-24h"
    description = "Temporary break-glass access, expires 2026-07-05T00:00:00Z"
    expression  = "request.time < timestamp('2026-07-05T00:00:00.000Z')"
  }
}
```

**Resource tag-based access:**
```hcl
# Only allow access to resources tagged as "environment:prod"
condition {
  title      = "prod-only"
  expression = "resource.matchTag('my-org/environment', 'prod')"
}
```

**Request path restriction (Cloud Run/API Gateway):**
```hcl
condition {
  title      = "read-api-only"
  expression = "request.path.startsWith('/api/v1/read')"
}
```

### Conditions Caveats

- Conditions on `roles/owner` and `roles/editor` are not supported
- Not all GCP services support conditions — check the [supported resources list](https://cloud.google.com/iam/docs/conditions-resource-attributes)
- Failed condition evaluations are logged; build alerting on condition denials for sensitive resources
- CEL expressions are evaluated per-request, so complex expressions add latency

---

## Audit Logging

Every IAM change generates an Admin Activity audit log. These cannot be disabled. Data Access audit logs (who read what) are optional and off by default — enable them for sensitive APIs.

```hcl
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
```

Key log events to alert on:
- `google.iam.admin.v1.CreateServiceAccountKey` — someone created a key (should be impossible if you've set the org policy)
- `google.iam.admin.v1.SetIamPolicy` — IAM binding changed
- `google.iam.credentials.v1.GenerateAccessToken` — token generated via impersonation
- Any `PERMISSION_DENIED` on sensitive APIs (canary for compromised credentials)

---

## References

- [IAM overview](https://cloud.google.com/iam/docs/overview) — Google Cloud
- [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation) — Google Cloud
- [WIF with GitHub Actions](https://cloud.google.com/blog/products/identity-security/enabling-keyless-authentication-from-github-actions) — Google Cloud Blog
- [Org policy constraints reference](https://cloud.google.com/resource-manager/docs/organization-policy/org-policy-constraints) — Google Cloud
- [IAM Conditions overview](https://cloud.google.com/iam/docs/conditions-overview) — Google Cloud
- [CEL specification](https://github.com/google/cel-spec) — GitHub
