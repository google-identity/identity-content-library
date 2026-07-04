# Cross-Cloud: Azure Workloads Authenticating to GCP via WIF

**Audience:** Engineers running workloads on Azure (App Service, AKS, Azure Functions, VMs) that need to call Google Cloud APIs without a service account key.

**Last updated:** 2026-07-04

---

## How It Works

Azure Managed Identities and App Registrations issue OIDC tokens that GCP's Workload Identity Federation can validate. The exchange is similar to the AWS flow but uses the OIDC provider type instead of the AWS-specific type.

```
Azure Workload (with Managed Identity or App Registration)
  │
  ├─ Fetches OIDC token from Azure IMDS or MSAL
  │    GET http://169.254.169.254/metadata/identity/oauth2/token
  │         ?audience=api://AzureADTokenExchange
  │
  └─ Calls GCP Security Token Service (STS)
       │  POST https://sts.googleapis.com/v1/token
       │  subject_token = Azure OIDC token
       │
       └─ Gets short-lived GCP federated token
            │
            └─ (Optional) Exchanges for service account access token
```

The OIDC token Azure issues is a standard JWT signed by Azure's OIDC infrastructure. GCP fetches Azure's JWKS endpoint to verify the signature — no Azure-side configuration is needed beyond the Managed Identity itself.

---

## Azure Identity Types and When to Use Each

**System-Assigned Managed Identity** (preferred for single-service workloads)
- Created and destroyed with the Azure resource
- Can't be shared across resources
- Zero-configuration — no client ID to manage

**User-Assigned Managed Identity** (preferred when multiple Azure resources share a GCP identity)
- Created independently, attached to resources
- Can be attached to multiple Azure resources
- Survives resource recreation

**App Registration with Federated Credentials** (required for AKS workloads with Azure Workload Identity)
- Explicit OIDC federation setup in Entra ID
- More control over token audiences and lifetimes
- The right choice for AKS with Azure Workload Identity operator

---

## Step 1: Configure the WIF Pool and OIDC Provider (GCP)

### With gcloud

```bash
PROJECT_ID="my-gcp-project"
PROJECT_NUMBER="123456789012"
POOL_ID="azure-workloads"
PROVIDER_ID="azure-tenant-abc123"
AZURE_TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Create the WIF pool
gcloud iam workload-identity-pools create "${POOL_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --display-name="Azure Workloads"

# Create the OIDC provider for Azure
gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_ID}" \
  --issuer-uri="https://sts.windows.net/${AZURE_TENANT_ID}/" \
  --allowed-audiences="api://AzureADTokenExchange" \
  --attribute-mapping="google.subject=assertion.sub,attribute.tenant=assertion.tid,attribute.object_id=assertion.oid" \
  --attribute-condition="assertion.tid == '${AZURE_TENANT_ID}'" \
  --display-name="Azure Tenant ${AZURE_TENANT_ID}"
```

**Issuer URI note:** Azure uses two OIDC issuers. For Managed Identity tokens:
- `https://sts.windows.net/{tenant-id}/` — the v1 endpoint, used by most Azure Managed Identity IMDS calls
- `https://login.microsoftonline.com/{tenant-id}/v2.0` — the v2 endpoint, used when you explicitly request v2 tokens

Check which issuer appears in your token's `iss` claim and use that in the WIF provider. Mismatch causes a 400 from GCP STS.

### With Terraform

```hcl
resource "google_iam_workload_identity_pool" "azure" {
  workload_identity_pool_id = "azure-workloads"
  project                   = var.project_id
  display_name              = "Azure Workloads"
}

resource "google_iam_workload_identity_pool_provider" "azure" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.azure.workload_identity_pool_id
  workload_identity_pool_provider_id = "azure-tenant-${substr(var.azure_tenant_id, 0, 8)}"
  project                            = var.project_id
  display_name                       = "Azure Tenant"

  oidc {
    issuer_uri        = "https://sts.windows.net/${var.azure_tenant_id}/"
    allowed_audiences = ["api://AzureADTokenExchange"]
  }

  attribute_mapping = {
    "google.subject"      = "assertion.sub"
    "attribute.tenant"    = "assertion.tid"
    "attribute.object_id" = "assertion.oid"
  }

  # Critical: lock down to your tenant
  attribute_condition = "assertion.tid == '${var.azure_tenant_id}'"
}
```

---

## Step 2: Grant Access to GCP Resources

The Azure Managed Identity's `object_id` (OID) is its stable identifier. Use it in GCP IAM bindings.

Find your Managed Identity's object ID:
```bash
az identity show \
  --name my-managed-identity \
  --resource-group my-resource-group \
  --query principalId \
  --output tsv
```

Grant access via `principalSet` using the OID attribute:

```bash
OBJECT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Direct resource binding (preferred)
gcloud storage buckets add-iam-policy-binding gs://my-bucket \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.object_id/${OBJECT_ID}" \
  --role="roles/storage.objectViewer"

# Or via service account impersonation
SA_EMAIL="gcp-sa@${PROJECT_ID}.iam.gserviceaccount.com"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --project="${PROJECT_ID}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.object_id/${OBJECT_ID}"
```

---

## Step 3: Configure the Azure Workload

### VM or App Service with System-Assigned Managed Identity

Generate the credential configuration:

```bash
gcloud iam workload-identity-pools create-cred-config \
  "projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}" \
  --azure \
  --app-id-uri "api://AzureADTokenExchange" \
  --output-file=gcp-credential-config.json \
  --service-account="${SA_EMAIL}"  # omit if direct resource binding
```

Set the environment variable:
```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/gcp-credential-config.json
```

The Google auth library will:
1. Call the Azure IMDS endpoint to get an OIDC token for `api://AzureADTokenExchange`
2. Exchange it at GCP STS for a federated token
3. Optionally exchange that for a service account access token

### AKS with Azure Workload Identity

Azure Workload Identity projects OIDC tokens directly into pods via a mounted volume. This is the correct approach for AKS — it avoids the IMDS endpoint (which is node-scoped) and gives each pod its own identity.

Setup involves:
1. An Entra ID App Registration with a federated credential
2. The Azure Workload Identity webhook installed on the cluster
3. A Kubernetes ServiceAccount annotated with the App Registration client ID

The token audience for AKS-projected tokens is your App Registration client ID, not `api://AzureADTokenExchange`. Configure your WIF provider's `allowed_audiences` accordingly, or create a separate WIF provider for AKS.

```bash
AKS_APP_CLIENT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

gcloud iam workload-identity-pools providers create-oidc "aks-${CLUSTER_NAME}" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="${POOL_ID}" \
  --issuer-uri="https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0" \
  --allowed-audiences="${AKS_APP_CLIENT_ID}" \
  --attribute-mapping="google.subject=assertion.sub,attribute.app_id=assertion.appid" \
  --attribute-condition="assertion.appid == '${AKS_APP_CLIENT_ID}'"
```

---

## Attribute Conditions: The Guard Rail You Must Set

**Always set `attribute_condition`** on your WIF provider. At minimum, lock it to your Azure tenant:

```
# Minimum: only your tenant can exchange tokens
assertion.tid == 'your-tenant-id'

# Better: only a specific managed identity (by object ID)
assertion.tid == 'your-tenant-id' && assertion.oid == 'managed-identity-object-id'

# For App Registrations: lock to the specific app
assertion.tid == 'your-tenant-id' && assertion.appid == 'app-registration-client-id'
```

Without `attribute_condition`, any authenticated identity in any Azure tenant can exchange tokens if they can obtain a token with the right audience. The `allowed_audiences` check alone is not sufficient.

---

## Debugging Token Exchange Issues

The most common failure is issuer mismatch. To check what issuer your Azure token actually uses:

```bash
# On the Azure VM/container — get the raw token
TOKEN=$(curl -s -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&audience=api://AzureADTokenExchange&resource=api://AzureADTokenExchange" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Decode the payload (no verification needed — just inspect the claims)
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool | grep -E '"iss"|"oid"|"tid"|"aud"'
```

Compare the `iss` value to your WIF provider's `issuer_uri`. They must match exactly, including trailing slash.

---

## Audit Logging

GCP audit logs record:
```
principalSubject: principal://iam.googleapis.com/projects/.../workloadIdentityPools/azure-workloads/subject/<azure-oid>
```

Azure Monitor logs the IMDS token request. Both sides create independent audit trails — correlate them using the timestamp and the GCP STS request.

---

## Common Pitfalls

**Issuer v1 vs v2:** Managed Identity IMDS usually returns v1 tokens (`sts.windows.net/{tenant}/`). App Registrations using MSAL typically return v2 tokens (`login.microsoftonline.com/{tenant}/v2.0`). Verify before configuring the WIF provider.

**Missing `resource` parameter:** When calling the Azure IMDS endpoint, you must specify `resource=api://AzureADTokenExchange` (or use the `audience` parameter on newer IMDS versions). Without this, the token's audience won't match the WIF provider's `allowed_audiences`.

**User-Assigned vs System-Assigned OID:** User-Assigned Managed Identities have a stable OID that doesn't change when detached/reattached. System-Assigned OIDs are stable for the resource's lifetime but disappear when the resource is deleted. Both work fine for WIF bindings.

**AKS IMDS is node-scoped:** The IMDS endpoint on AKS nodes returns the node pool's identity, not a pod-specific identity. Use Azure Workload Identity for pod-level granularity.

---

## References

- [Google Cloud: Configure WIF for Azure](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-clouds#azure)
- [Azure: Managed Identity Overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview)
- [Azure: Workload Identity for AKS](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Azure IMDS token endpoint](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/how-to-use-vm-token)
