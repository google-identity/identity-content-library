# Azure Identity Patterns

This section covers Azure Entra ID (formerly Azure AD) identity patterns and cross-cloud federation from Azure to Google Cloud.

## Contents

| Topic | Path |
|-------|------|
| Azure EntraID to GCP via WIF (full example) | [../cross-cloud/azure-to-gcp-wif.md](../cross-cloud/azure-to-gcp-wif.md) |
| WIF best practices (blog) | [../blog/wif-best-practices.md](../blog/wif-best-practices.md) |

## Azure Entra ID Fundamentals for Cross-Cloud Work

Azure workloads use Managed Identities or App Registrations as their identity primitive. When federating to Google Cloud, Managed Identities are strongly preferred — they're automatically provisioned and have no credentials to manage.

### Key Azure Identity Primitives

- **System-Assigned Managed Identity**: Lifecycle tied to the resource (VM, AKS pod, Function App). Automatically deleted when the resource is deleted. One identity per resource.
- **User-Assigned Managed Identity (UAMI)**: A standalone Azure resource. Can be attached to multiple compute resources. Preferred for shared workloads or when you need identity continuity independent of compute.
- **App Registration + Service Principal**: The Azure equivalent of a service account. Used for human-initiated flows and some service-to-service cases. For machine workloads, prefer Managed Identities.
- **Workload Identity Federation (Azure)**: Azure's own OIDC federation feature — allows App Registrations to trust external OIDC tokens. Not the same as GCP WIF, but used for the reverse direction (Kubernetes pods federating to Azure).

### How Azure Managed Identity Works with GCP WIF

When an Azure workload federates to GCP:

1. The Azure workload requests an OIDC token from the Azure Instance Metadata Service (IMDS), specifying `api://AzureADTokenExchange` as the audience.
2. Azure EntraID issues a signed JWT containing the managed identity's `object_id`, `client_id`, `tenant_id`, and other claims.
3. The workload presents this JWT to Google Cloud STS, which validates it against the configured OIDC provider (issuer: `https://sts.windows.net/TENANT_ID/`).
4. Google Cloud issues a federated token scoped to the matching WIF pool principal.

**Critical detail:** The audience you request from IMDS must exactly match the `allowed_audiences` configured in your GCP OIDC provider. The Google-recommended value is `api://AzureADTokenExchange`, but you can use any value — the point is consistency.

### Managed Identity vs. App Registration

For machine-to-machine GCP federation, use a User-Assigned Managed Identity unless you have a specific reason not to:

| | Managed Identity | App Registration |
|---|---|---|
| Credential management | None — Azure manages the keys | Client secret or certificate must be managed |
| Scope | One identity, many resources | One identity, one app |
| Best for | VM/AKS/Function workloads | Custom apps, non-Azure compute |
| Audit trail | Bound to Azure resource | Principal-level |

### Object ID vs. Client ID

This is the most common Azure WIF misconfiguration: confusing the managed identity's Object ID with its Client ID.

- **Client ID** (`client_id` / `appid` JWT claim): The Application ID. Used when calling Azure APIs to specify which identity to use.
- **Object ID** (`oid` JWT claim): The service principal's object ID in the directory. This is what appears in the JWT `sub` claim for managed identities.

When you bind an IAM principal in GCP using `assertion.sub` or `assertion.oid`, you're using the Object ID. To find it:

```bash
# Azure CLI
az identity show --name MY_UAMI --resource-group MY_RG --query principalId -o tsv
```

### Fetching the IMDS Token

From within an Azure VM or container with a managed identity attached:

```bash
# System-assigned managed identity
TOKEN=$(curl -s \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://AzureADTokenExchange" \
  -H "Metadata: true" | jq -r .access_token)

# User-assigned managed identity (specify client_id)
TOKEN=$(curl -s \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=api://AzureADTokenExchange&client_id=UAMI_CLIENT_ID" \
  -H "Metadata: true" | jq -r .access_token)
```

**AKS note:** AKS with Azure Workload Identity uses a projected service account token, not IMDS. The token path and fetch mechanism differ — see the [Azure Workload Identity documentation](https://azure.github.io/azure-workload-identity/docs/) and configure your GCP provider to accept the corresponding issuer.

## Best Practices

**Use User-Assigned Managed Identities**: They're reusable, have a stable Object ID that survives compute changes, and are easier to manage at scale. System-assigned identities are convenient for one-offs but create IAM binding churn when you reprovision VMs.

**Lock GCP WIF binding to the Object ID**: Bind `principal://iam.googleapis.com/.../subject/OBJECT_ID` rather than a broad `principalSet` when you're federating a specific managed identity. The Object ID is stable for the lifecycle of the managed identity.

**Enforce tenant isolation with `attribute_condition`**: Always include `attribute_condition = "assertion.tid == \"TENANT_ID\""` in your GCP provider. Without it, any Azure tenant can federate if they produce a JWT with a matching subject.

**Separate pools per Azure environment**: If you have Azure workloads in dev and prod subscriptions, use separate GCP WIF pools — not separate providers in the same pool. Pools define the principal namespace; cross-pool isolation is cleaner.
