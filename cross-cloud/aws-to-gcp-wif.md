# Cross-Cloud: AWS Workloads Authenticating to GCP via WIF

**Audience:** Engineers running workloads on AWS (Lambda, EC2, ECS, EKS) that need to call Google Cloud APIs without a service account key.

**Last updated:** 2026-07-04

---

## How It Works

AWS workloads carry an OIDC-compatible identity: EC2 instance identity documents, EKS Service Account tokens (IRSA), and Lambda execution role tokens can all be exchanged for GCP credentials via Workload Identity Federation.

The flow:

```
AWS Workload
  │
  ├─ Gets AWS STS token or OIDC token (free, automatic)
  │
  └─ Calls GCP Security Token Service (STS)
       │  POST https://sts.googleapis.com/v1/token
       │  subject_token = AWS STS token
       │  audience = WIF provider resource name
       │
       └─ Gets short-lived GCP federated token
            │
            └─ (Optional) Exchanges for service account access token
                 via generateAccessToken
```

No service account key is ever created or stored. The AWS identity is the credential.

---

## Prerequisites

- A GCP project with billing enabled
- An AWS account with an IAM role your workload already assumes
- `gcloud` CLI or Terraform 1.5+

---

## Step 1: Configure the WIF Pool and Provider (GCP)

### With gcloud

```bash
PROJECT_ID="my-gcp-project"
PROJECT_NUMBER="123456789012"
POOL_ID="aws-workloads"
PROVIDER_ID="aws-account-123456789"
AWS_ACCOUNT_ID="123456789012"

# Create the WIF pool
gcloud iam workload-identity-pools create "${POOL_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --display-name="AWS Workloads"

# Create the AWS provider
gcloud iam workload-identity-pools providers create-aws "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_ID}" \
  --account-id="${AWS_ACCOUNT_ID}" \
  --display-name="AWS Account ${AWS_ACCOUNT_ID}"
```

The AWS provider type uses AWS STS GetCallerIdentity as the verification mechanism — GCP calls AWS STS on your behalf to validate the presented token. This is more robust than raw OIDC because it verifies the actual AWS identity, not just a signed token.

### With Terraform

```hcl
resource "google_iam_workload_identity_pool" "aws" {
  workload_identity_pool_id = "aws-workloads"
  project                   = var.project_id
  display_name              = "AWS Workloads"
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws.workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-account-${var.aws_account_id}"
  project                            = var.project_id
  display_name                       = "AWS Account ${var.aws_account_id}"

  aws {
    account_id = var.aws_account_id
  }

  attribute_mapping = {
    "google.subject"        = "assertion.arn"
    "attribute.aws_role"    = "assertion.arn.extract('assumed-role/{role}/')"
    "attribute.aws_account" = "assertion.account"
  }

  attribute_condition = "attribute.aws_account == '${var.aws_account_id}'"
}
```

---

## Step 2: Grant the AWS Identity Access to GCP Resources

Option A — Direct resource binding (preferred, no service account needed):

```bash
# Grant the AWS role access directly to a GCS bucket
gcloud storage buckets add-iam-policy-binding gs://my-bucket \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.aws_role/arn:aws:iam::${AWS_ACCOUNT_ID}:role/my-aws-role" \
  --role="roles/storage.objectViewer"
```

Option B — Service account impersonation (required if the GCP API doesn't support WIF directly):

```bash
SA_EMAIL="gcp-sa@${PROJECT_ID}.iam.gserviceaccount.com"

# Allow the AWS identity to impersonate the SA
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.aws_role/arn:aws:iam::${AWS_ACCOUNT_ID}:role/my-aws-role"
```

**Which APIs don't support WIF directly?** As of 2026, most major GCP APIs accept federated tokens. Exceptions include some legacy APIs and APIs that require service account impersonation for audit purposes. Check the API's documentation — look for "supports workload identity federation" in the auth section.

---

## Step 3: Configure the AWS Workload

### EC2 / ECS with Instance Profile

Install the Google Cloud SDK or use the `google-auth` library with Application Default Credentials. The credential configuration file tells ADC to use WIF:

```bash
# Generate the credential config file
gcloud iam workload-identity-pools create-cred-config \
  "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}" \
  --aws \
  --output-file=gcp-credential-config.json \
  --service-account="${SA_EMAIL}"  # omit if using direct resource binding
```

This generates a JSON file that instructs the Google auth libraries to:
1. Call `sts.amazonaws.com:443/` to get a signed GetCallerIdentity request
2. Present that to GCP STS in exchange for a federated token
3. (If SA impersonation configured) Call IAM generateAccessToken

Set the environment variable on your workload:
```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/gcp-credential-config.json
```

Your application code doesn't change — ADC handles the exchange transparently.

### Lambda

For Lambda, generate the same credential config file and package it with your function, or store it in SSM Parameter Store and load it at cold start. The Lambda execution role provides the AWS identity automatically.

```python
import os
import boto3
import google.auth
from google.cloud import storage

# GOOGLE_APPLICATION_CREDENTIALS points to the cred config JSON
credentials, project = google.auth.default(
    scopes=["https://www.googleapis.com/auth/cloud-platform"]
)
client = storage.Client(credentials=credentials, project="my-gcp-project")
```

### EKS with IRSA

IRSA (IAM Roles for Service Accounts) gives each pod its own AWS IAM role via a projected OIDC token. You can layer GCP WIF on top:

1. Your EKS cluster has an OIDC issuer URL
2. Create a WIF OIDC provider pointing to the EKS OIDC issuer
3. Map the EKS service account token to GCP credentials

This differs from the AWS STS flow above — it uses the OIDC provider type instead of the AWS provider type.

```hcl
resource "google_iam_workload_identity_pool_provider" "eks" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws.workload_identity_pool_id
  workload_identity_pool_provider_id = "eks-my-cluster"
  project                            = var.project_id

  oidc {
    issuer_uri = var.eks_oidc_issuer_url  # e.g., https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE
    allowed_audiences = ["sts.amazonaws.com"]
  }

  attribute_mapping = {
    "google.subject"               = "assertion.sub"
    "attribute.namespace"          = "assertion['kubernetes.io/serviceaccount/namespace']"
    "attribute.service_account"    = "assertion['kubernetes.io/serviceaccount/name']"
  }

  attribute_condition = "attribute.namespace == 'production'"
}
```

---

## Attribute Conditions: The Guard Rail You Must Set

**Always set `attribute_condition`** on your WIF provider. Without it, *any* identity in the AWS account can exchange tokens. The condition restricts which AWS identities are valid.

Examples:

```
# Only a specific role
attribute.aws_role == "arn:aws:iam::123456789012:role/my-app-role"

# Any role in your account (minimum bar — not specific enough for most use cases)
attribute.aws_account == "123456789012"

# Roles matching a prefix
attribute.aws_role.startsWith("arn:aws:iam::123456789012:role/gcp-")
```

The condition is evaluated server-side by GCP. If it fails, the token exchange is rejected before any GCP resource is accessed.

---

## Token Lifetime and Caching

Federated tokens from GCP STS are valid for 1 hour. Service account access tokens (from generateAccessToken) are also 1 hour maximum.

The Google auth libraries cache and refresh tokens automatically. If you're making raw HTTP calls, cache the token and refresh before expiry (request a new one when `expires_in < 300` seconds remaining).

---

## Audit Logging

GCP audit logs record the federated identity in `authenticationInfo.principalSubject`, e.g.:

```
principalSubject: principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/aws-workloads/subject/arn:aws:sts::123456789012:assumed-role/my-app-role/session-name
```

AWS CloudTrail logs the GCP STS GetCallerIdentity call. Both sides log independently.

---

## Common Pitfalls

**WIF pool in wrong project**: The pool must be in the project whose resources you're accessing, or you must grant the federated principal access across projects. Cross-project WIF binding works but adds complexity.

**Attribute mapping uses `assertion.arn` but condition checks `attribute.aws_role`**: Remember that `attribute.aws_role` is an extracted field you define in the mapping. If you change the mapping, update the condition.

**Forgetting the audience**: The credential config file's `audience` field must match the full WIF provider resource name. Mismatch causes a 400 from GCP STS.

**EC2 instance role vs assumed role ARN**: The `assertion.arn` for an EC2 instance role is `arn:aws:sts::ACCOUNT:assumed-role/ROLE-NAME/INSTANCE-ID`. Your attribute condition must account for the session suffix.

---

## References

- [Google Cloud: Configure WIF for AWS](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds)
- [Google Cloud: Create a credential configuration](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines)
- [AWS STS GetCallerIdentity](https://docs.aws.amazon.com/STS/latest/APIReference/API_GetCallerIdentity.html)
- [google-auth-library-python: External Credentials](https://google-auth.readthedocs.io/en/master/reference/google.auth.external_account.html)
