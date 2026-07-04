# Workload Identity Federation: Stop Using Service Account Keys

**Published:** July 4, 2026  
**Author:** Google Cloud Identity Engineering  
**Audience:** Senior engineers evaluating or operating Google Cloud workloads

---

Service account key files are a liability. They expire silently, they get committed to repos, they get emailed, they sit in CI environment variables that outlive the engineer who set them up. Workload Identity Federation (WIF) eliminates all of that — and if you're still issuing JSON key files to any non-human workload, this post is for you.

This isn't a feature overview. It's a field guide: how to configure WIF correctly for AWS, Azure, and GitHub Actions; which mistakes will burn you; and what your security posture should look like when you're done.

---

## Why WIF Beats Service Account Keys

Service account keys are a symmetric credential — whoever holds the file holds the identity. That creates three compounding problems:

1. **Rotation is manual and error-prone.** Keys are valid for up to 10 years unless explicitly rotated. Most teams set them and forget them.
2. **Distribution sprawl.** The moment you copy a key file into a CI secret, an S3 bucket, or a colleague's terminal, you've lost control of the credential surface.
3. **No provenance.** When a key is used, you know *which* service account — you don't know *from where*, *by what process*, or *on which machine*.

Workload Identity Federation replaces the key file with a trust relationship. Your workload presents a short-lived credential from its native platform (an AWS STS token, an Azure managed identity token, a GitHub Actions OIDC token), and Google Cloud exchanges it for a short-lived Google credential scoped to a specific service account — or, better, directly to a Workload Identity Pool principal. No keys to manage, no secrets to rotate.

The trust is grounded in the OIDC/SAML federation standards, not a proprietary mechanism. If your cloud provider or CI platform issues OIDC JWTs, WIF can consume them.

---

## Architecture Overview

The federation flow has four actors:

```
External workload (AWS EC2 / Azure VM / GitHub runner)
  │
  │  1. Get native short-lived credential
  ▼
External OIDC/SAML IdP (AWS STS / Azure AD / GitHub Actions)
  │
  │  2. Exchange for Google federated credential
  ▼
Google Cloud STS (securetoken.googleapis.com)
  │
  │  3. (Optional) Impersonate service account
  ▼
Google Cloud APIs (GCS, BigQuery, etc.)
```

Step 3 is optional with the direct resource access feature: you can grant IAM permissions directly to a Workload Identity Pool principal (e.g., `principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL_ID/attribute.aws_role/arn:aws:iam::ACCOUNT_ID:role/ROLE_NAME`) without needing a service account. This is preferable when you can do it — it removes a layer and eliminates impersonation scope confusion.

---

## Configuring WIF for AWS Workloads

### What You're Federating

AWS workloads can authenticate using instance metadata (EC2), task metadata (ECS/Fargate), or role credentials (Lambda, EKS IRSA). In all cases, the credential is an AWS STS `AssumeRoleWithWebIdentity` or similar call. WIF supports AWS-native federation using the `aws` provider type, which handles the AWS STS request signing internally.

### Terraform: Full Setup

```hcl
# variables.tf
variable "aws_account_id" {
  type        = string
  description = "AWS account ID allowed to federate"
}

variable "aws_role_name" {
  type        = string
  description = "IAM role name (not ARN) that will federate"
}

variable "project_id" {
  type = string
}

variable "project_number" {
  type = string
}
```

```hcl
# wif_aws.tf
resource "google_iam_workload_identity_pool" "aws_pool" {
  project                   = var.project_id
  workload_identity_pool_id = "aws-prod-pool"
  display_name              = "AWS Production Pool"
  description               = "Federation for AWS production workloads"
}

resource "google_iam_workload_identity_pool_provider" "aws_provider" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-provider"
  display_name                       = "AWS Provider"

  attribute_mapping = {
    "google.subject"        = "assertion.arn"
    "attribute.aws_account" = "assertion.account"
    "attribute.aws_role"    = "assertion.arn.extract('assumed-role/{role}/')"
    "attribute.aws_ec2_instance" = "assertion.arn.extract('assumed-role/{role_and_instance}/').extract('/{instance}')"
  }

  # Only allow tokens from your specific AWS account
  attribute_condition = "assertion.account == \"${var.aws_account_id}\""

  aws {
    account_id = var.aws_account_id
  }
}

# Grant the specific AWS role permission to impersonate a service account
resource "google_service_account_iam_member" "aws_wif_binding" {
  service_account_id = google_service_account.workload_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws_pool.name}/attribute.aws_role/arn:aws:iam::${var.aws_account_id}:assumed-role/${var.aws_role_name}"
}

resource "google_service_account" "workload_sa" {
  project      = var.project_id
  account_id   = "aws-workload-sa"
  display_name = "Service account for AWS federated workloads"
}
```

### gcloud Equivalent

```bash
# Create the pool
gcloud iam workload-identity-pools create aws-prod-pool \
  --location="global" \
  --display-name="AWS Production Pool" \
  --project=PROJECT_ID

# Create the AWS provider
gcloud iam workload-identity-pools providers create-aws aws-provider \
  --location="global" \
  --workload-identity-pool=aws-prod-pool \
  --account-id=AWS_ACCOUNT_ID \
  --attribute-mapping="google.subject=assertion.arn,attribute.aws_account=assertion.account,attribute.aws_role=assertion.arn.extract('assumed-role/{role}/')" \
  --attribute-condition="assertion.account == 'AWS_ACCOUNT_ID'" \
  --project=PROJECT_ID

# Bind the AWS role to the service account
gcloud iam service-accounts add-iam-policy-binding workload-sa@PROJECT_ID.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/aws-prod-pool/attribute.aws_role/arn:aws:iam::AWS_ACCOUNT_ID:assumed-role/ROLE_NAME" \
  --project=PROJECT_ID
```

### Credential Configuration on the AWS Side

On your EC2 or ECS task, use Application Default Credentials with a generated credential configuration file:

```bash
gcloud iam workload-identity-pools create-cred-config \
  projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/aws-prod-pool/providers/aws-provider \
  --service-account=workload-sa@PROJECT_ID.iam.gserviceaccount.com \
  --aws \
  --output-file=google-credentials.json
```

Then set `GOOGLE_APPLICATION_CREDENTIALS=google-credentials.json` in your workload. The credential config is **not a secret** — it contains no key material, just metadata about how to exchange tokens.

---

## Configuring WIF for Azure Workloads

Azure Managed Identities issue OIDC JWTs through the Azure Instance Metadata Service. Unlike AWS, Azure uses a standard OIDC provider, so the `oidc` provider type applies.

```hcl
resource "google_iam_workload_identity_pool" "azure_pool" {
  project                   = var.project_id
  workload_identity_pool_id = "azure-prod-pool"
  display_name              = "Azure Production Pool"
}

resource "google_iam_workload_identity_pool_provider" "azure_provider" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.azure_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "azure-oidc"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.tenant_id"  = "assertion.tid"
    "attribute.object_id"  = "assertion.oid"
  }

  # Lock to your Azure tenant
  attribute_condition = "assertion.tid == \"AZURE_TENANT_ID\""

  oidc {
    issuer_uri        = "https://sts.windows.net/AZURE_TENANT_ID/"
    allowed_audiences = ["api://AzureADTokenExchange"]
  }
}

resource "google_service_account_iam_member" "azure_wif_binding" {
  service_account_id = google_service_account.workload_sa.name
  role               = "roles/iam.workloadIdentityUser"
  # Bind to the specific managed identity's object ID
  member = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.azure_pool.name}/subject/MANAGED_IDENTITY_OBJECT_ID"
}
```

**Important:** The `allowed_audiences` value must match what your Azure workload requests as the audience when fetching the token. The value `api://AzureADTokenExchange` is the Microsoft-recommended value for federation scenarios. If you use a custom audience, use that instead — and make sure your Google provider matches it exactly.

On the Azure side, your workload fetches a token from IMDS:

```bash
# From within an Azure VM with a managed identity
TOKEN=$(curl -s \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://AzureADTokenExchange" \
  -H "Metadata: true" | jq -r .access_token)
```

---

## Configuring WIF for GitHub Actions

GitHub Actions is the simplest federation case and the one most teams reach for first. GitHub Actions runners emit OIDC JWTs with rich claims: repository, branch, ref, environment, and actor.

```hcl
resource "google_iam_workload_identity_pool" "github_pool" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions Pool"
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
    "attribute.environment"      = "assertion.environment"
    "attribute.workflow"         = "assertion.workflow"
  }

  # Lock to your GitHub org
  attribute_condition = "assertion.repository_owner == \"YOUR_GITHUB_ORG\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
    # Do NOT set allowed_audiences unless you've customized the audience claim
    # The default audience "https://token.actions.githubusercontent.com" must match
  }
}

# Bind a specific repository (not the whole org) to the service account
resource "google_service_account_iam_member" "github_repo_binding" {
  service_account_id = google_service_account.deploy_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/YOUR_GITHUB_ORG/YOUR_REPO"
}
```

### GitHub Actions Workflow

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # Required — without this, no OIDC token is issued
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: 'projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions-pool/providers/github-provider'
          service_account: 'deploy-sa@PROJECT_ID.iam.gserviceaccount.com'

      - name: Use Google Cloud
        run: gcloud storage ls gs://my-bucket/
```

The `google-github-actions/auth` action handles the OIDC token exchange transparently. After that step, all `gcloud` commands and Google Cloud client libraries use the federated credential automatically.

---

## Common Mistakes That Will Burn You

### 1. Missing `attribute_condition`

Without an `attribute_condition`, your pool trusts *any* identity from the provider's issuer. For GitHub Actions, that means any GitHub repository can federate as your pool. For AWS, that means any account using your provider type.

**Always set `attribute_condition`.** Minimum: lock to your org/account. For higher-security deployments, lock to a specific repository, role, or environment.

```hcl
# Wrong: no condition
attribute_condition = ""

# Right: lock to org
attribute_condition = "assertion.repository_owner == \"your-org\""

# Better: lock to repo + protected environment
attribute_condition = "assertion.repository == \"your-org/your-repo\" && assertion.environment == \"production\""
```

### 2. Binding the Pool Principal Instead of a Scoped Attribute

A common mistake is granting `roles/iam.workloadIdentityUser` to `principalSet://...//` with a wildcard or the pool root, rather than a specific attribute value.

```hcl
# Wrong: grants any identity in the pool
member = "principalSet://iam.googleapis.com/.../workloadIdentityPools/pool-id/*"

# Right: grants only identities from a specific repo
member = "principalSet://iam.googleapis.com/.../workloadIdentityPools/pool-id/attribute.repository/org/repo"
```

Even if your `attribute_condition` on the provider is correct, the IAM binding is a second layer. Apply both.

### 3. Forgetting `id-token: write` in GitHub Actions

Without `permissions.id-token: write`, the runner doesn't receive an OIDC token. The auth action will silently fail or fall back to other credential sources. This is the most common GitHub Actions WIF debugging question.

### 4. Using `google.subject` Bindings Without Understanding AWS ARN Format

For AWS, `assertion.arn` is the session ARN, which for assumed roles looks like:
```
arn:aws:sts::ACCOUNT_ID:assumed-role/ROLE_NAME/SESSION_NAME
```

If you bind `google.subject` directly, the session name suffix means every new session has a different subject. Use `attribute.aws_role` (extracted with `assertion.arn.extract('assumed-role/{role}/')`) and bind to that instead.

### 5. Using the Wrong Audience for Azure

Azure's IMDS token endpoint requires you to specify the resource/audience. If you request `https://management.azure.com/` (the ARM audience) and your Google provider expects `api://AzureADTokenExchange`, the token will be rejected. Match the audience you configure in the provider to what you request from IMDS.

### 6. Putting the Credential Config File in Source Control Without Understanding What It Contains

The credential configuration JSON is **not a secret** — it's a routing file with no key material. But teams that don't understand this sometimes over-classify it (blocking automation) or under-classify it (worrying the wrong thing is at risk). The actual sensitive asset is the IAM binding, not the config file.

---

## Security Posture Recommendations

### Use Direct Resource Access When Possible

When you can grant IAM roles directly to a `principalSet://` without a service account intermediary, do it. Service account impersonation (`roles/iam.serviceAccountTokenCreator`) is a powerful permission — if the WIF principal can impersonate a service account, and that service account has broad permissions, you've created an indirect privilege escalation path.

Direct resource access binds IAM policies on resources directly to WIF pool principals. Use it.

```bash
# Grant GCS access directly to a GitHub Actions repo's principal set
gcloud storage buckets add-iam-policy-binding gs://my-bucket \
  --role=roles/storage.objectViewer \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions-pool/attribute.repository/org/repo"
```

### Scope Bindings to the Narrowest Identity

Never grant pool-level bindings when you can grant attribute-scoped bindings. Rank from best to worst:

1. `principal://...subject/SPECIFIC_SUBJECT` — single identity only
2. `principalSet://...attribute.ATTR/VALUE` — all identities sharing an attribute
3. `principalSet://.../*` — all identities in the pool (almost never appropriate)

### Enable Organization Policy Constraints

Set the `iam.workloadIdentityPoolProviders.allowedIdPs` constraint at the org level to allowlist which external identity providers can be configured. This prevents shadow pools that federate with attacker-controlled issuers.

```hcl
resource "google_org_policy_policy" "restrict_wif_providers" {
  name   = "organizations/ORG_ID/policies/iam.workloadIdentityPoolProviders.allowedIdPs"
  parent = "organizations/ORG_ID"

  spec {
    rules {
      values {
        allowed_values = [
          "https://token.actions.githubusercontent.com",
          "https://sts.windows.net/AZURE_TENANT_ID/",
        ]
      }
    }
  }
}
```

### Audit Logs Are Your Control Plane

WIF exchanges appear in Cloud Audit Logs as `sts.googleapis.com/GenerateIdentityBindingAccessToken` events. These logs include the external subject, the pool and provider used, the resulting Google principal, and the resource or service account being accessed.

Set up log-based alerts for:
- Federation from unexpected subjects (e.g., an attribute value not matching your known repos)
- Unusually high token exchange rates (credential stuffing or misconfigured retry loops)
- Impersonation of high-privilege service accounts

```bash
gcloud logging sinks create wif-audit-sink \
  bigquery.googleapis.com/projects/PROJECT_ID/datasets/security_audit \
  --log-filter='protoPayload.serviceName="sts.googleapis.com" AND protoPayload.methodName="google.identity.sts.v1.SecurityTokenService.ExchangeToken"'
```

### Pool Lifecycle Management

Create separate pools per environment (dev, staging, prod) — not just separate providers within one pool. Pools are the principal namespace boundary. A misconfiguration in a dev provider shouldn't be able to affect prod resources.

```
Pool: github-dev-pool    → dev service accounts, dev buckets
Pool: github-prod-pool   → prod service accounts, prod buckets (stricter conditions)
Pool: aws-prod-pool      → AWS-originated access to prod resources
```

---

## Migration Path from Service Account Keys

If you're migrating existing workloads off JSON keys:

1. **Audit current keys**: `gcloud iam service-accounts keys list --iam-account=SA_EMAIL --project=PROJECT_ID`. Any key not listed as user-managed was auto-created and should be investigated.

2. **Create WIF pools and providers** for each source (one per external platform, or one per environment).

3. **Generate credential configuration files** for each workload using `gcloud iam workload-identity-pools create-cred-config`. Deploy these alongside your workload.

4. **Run both credentials in parallel** using `GOOGLE_APPLICATION_CREDENTIALS` for the new credential config. Monitor the STS audit logs to confirm federation is working.

5. **Disable the JSON keys** once WIF is confirmed working. Don't delete them immediately — disable first so you can re-enable if needed during the transition window.

6. **Delete the keys** after a monitoring period (typically 2 weeks is enough to catch any missed workload).

7. **Set the org policy** to block key creation: `iam.disableServiceAccountKeyCreation`. This is the endgame — it prevents future key sprawl at the source.

---

## The Bottom Line

WIF is not complicated once you understand the trust model. The hard part is:
- Scoping conditions correctly (be specific, not broad)
- Using direct resource access over service account impersonation
- Understanding which identity attribute to bind at the IAM level

The migration from service account keys to WIF is a one-time investment that pays off continuously: no key rotation, no key sprawl, no "who left this key in the repo" incidents. For any workload running on AWS, Azure, or GitHub Actions, there's no excuse for still using JSON keys.

If you're starting fresh: don't create keys. If you're migrating: audit first, then disable, then delete.

---

*More identity architecture patterns at [Google Cloud Identity](https://github.com/google-identity). Questions? Open an issue on the repo.*
