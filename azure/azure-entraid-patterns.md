# Azure Entra ID Patterns for Identity Engineers

**Audience:** Engineers working with Azure Entra ID (formerly Azure AD), especially those integrating Azure workloads with GCP or managing cross-cloud identity patterns.

**Last updated:** 2026-07-04

---

## Azure Machine Identity Primitives

| Identity Type | Use Case | Credential Required |
|--------------|----------|---------------------|
| System-Assigned Managed Identity | Single Azure resource | None — IMDS provides token |
| User-Assigned Managed Identity | Shared across resources, or portable | None — IMDS provides token |
| App Registration + Federated Credential | AKS pods, cross-tenant, CI/CD | None — OIDC federation |
| App Registration + Client Secret | Legacy M2M | Client secret (rotate manually) |
| App Registration + Certificate | M2M (better than secret) | Certificate (auto-rotate via Key Vault) |

For Azure workloads: Managed Identity is the default. For AKS pods: App Registration with Federated Credential (Azure Workload Identity). For everything else that must use a credential: certificate over secret.

---

## Managed Identity vs App Registration

These serve different purposes and are frequently confused.

**Managed Identity:** An identity attached to an Azure resource. The credential is managed by Azure — you never see or store it. The identity is an Entra ID service principal behind the scenes, but you don't interact with it as one.

**App Registration:** An application definition in Entra ID. When you create an App Registration, Entra ID creates a corresponding Enterprise Application (service principal) in your tenant. The App Registration holds credentials (secrets, certificates, or federated credentials) and defines API permissions.

For machine-to-machine API access within Azure: Managed Identity.
For M2M access to external services, or when you need to define specific OAuth scopes/permissions: App Registration.

---

## Azure Workload Identity for AKS

Azure Workload Identity is the pod-level identity solution for AKS. It replaces the deprecated AAD Pod Identity (aad-pod-identity) and uses the Kubernetes Projected Service Account Token standard.

Architecture:
1. AKS cluster has an OIDC issuer URL (`oidcIssuerProfile.issuerUrl`)
2. An Entra ID App Registration has a **Federated Credential** pointing to the cluster's OIDC issuer, a specific namespace, and a specific Kubernetes ServiceAccount name
3. The Azure Workload Identity mutating webhook injects AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE into pods whose ServiceAccount has the `azure.workload.identity/use: "true"` label
4. Azure SDK reads those env vars and calls MSAL to exchange the projected token for an Entra ID access token

Setup:

```bash
# Enable OIDC issuer on the cluster
az aks update \
  --name my-cluster \
  --resource-group my-rg \
  --enable-oidc-issuer \
  --enable-workload-identity

# Get the OIDC issuer URL
OIDC_ISSUER=$(az aks show \
  --name my-cluster \
  --resource-group my-rg \
  --query "oidcIssuerProfile.issuerUrl" \
  -o tsv)

# Create an App Registration
APP_ID=$(az ad app create --display-name my-app --query appId -o tsv)
az ad sp create --id $APP_ID

# Create a federated credential
az ad app federated-credential create \
  --id $APP_ID \
  --parameters "{
    \"name\": \"my-cluster-my-namespace-my-sa\",
    \"issuer\": \"${OIDC_ISSUER}\",
    \"subject\": \"system:serviceaccount:my-namespace:my-service-account\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }"
```

The `subject` field is exact — it must match the pod's ServiceAccount namespace and name.

---

## Conditional Access for Workloads

Conditional Access (CA) policies apply to interactive sign-ins by default. Workload identity CA (preview as of mid-2026) extends this to service principals and managed identities.

Workload identity CA can enforce:
- Location conditions (block tokens from unexpected IPs)
- Sign-in frequency (require re-authentication after N hours)

This is most useful for long-lived App Registrations with broad permissions. For Managed Identities and federated credentials (which are already short-lived and locked to specific conditions), workload CA adds minimal security value and operational complexity.

---

## OAuth 2.0 Token Types in Entra ID

Entra ID issues three types of tokens you'll encounter:

**Access tokens:** Bearer tokens authorizing access to a specific resource/audience. Valid 1 hour by default. Include claims the resource API evaluates for authorization.

**ID tokens:** Assertions about the user's identity. Used by the relying party (your app) to authenticate the user. Don't send ID tokens to APIs — they're for your app, not downstream services.

**Refresh tokens:** Long-lived tokens (default 24 hours, persistent for up to 90 days) that obtain new access tokens. For interactive (human) sign-ins only — machine clients use client credentials to get access tokens directly.

For M2M flows (client credentials), there are no refresh tokens — the client re-authenticates directly with Entra ID when the access token expires.

---

## App Roles vs API Permissions vs Delegated Permissions

Three authorization mechanisms in Entra ID are frequently confused:

**Delegated permissions:** The application acts on behalf of a signed-in user. The application can't do more than the user can. Used for user-facing apps. Requires user consent (or admin consent for org-wide).

**Application permissions:** The application acts as itself, with no user context. Used for background services, daemons, M2M. Requires admin consent. These are what your App Registration needs for machine-to-machine API access.

**App roles:** Custom roles you define on your own API. Other applications or users can be assigned to these roles. This is how you do RBAC for your own APIs in Entra ID.

For GCP WIF integration: if your Azure workload needs Azure API permissions (e.g., read from Azure resources) before calling GCP, use Application permissions on an App Registration. The Azure token produced is then exchanged at GCP WIF.

---

## SCIM Provisioning

SCIM (System for Cross-domain Identity Management) automates user and group provisioning between Entra ID and external systems. Entra ID acts as the SCIM client (provisioner) and pushes user/group changes to SCIM-compatible targets (Okta, Slack, ServiceNow, etc.).

SCIM runs as a background sync job. The provisioning scope is configurable — you can provision all users, members of specific groups, or users meeting attribute conditions.

For cross-cloud identity: SCIM is how you sync Entra ID groups to GCP Cloud Identity for human access management. The provisioning uses Entra ID's Enterprise Application configuration, not WIF.

---

## Audit Logging

**Entra ID Audit Logs** record identity operations: sign-ins, app registrations, role assignments, conditional access evaluations.

**Entra ID Sign-in Logs** record every token issuance. For Managed Identity and federated credential flows, look at the Managed Identity Sign-ins tab.

Key fields for cross-cloud tracing:
- `clientId` — the App Registration or Managed Identity
- `resourceId` — what was accessed (for federated credential flows, this is the GCP STS exchange resource)
- `ipAddress` — where the token request came from

For GCP WIF → Azure flows (or Azure → GCP), enable Diagnostic Settings on Entra ID to stream logs to Azure Monitor or Log Analytics for long-term retention and alerting.

---

## Common Mistakes

**Using client secrets instead of federated credentials for AKS**: Client secrets are rotatable but still require storage somewhere. Federated credentials eliminate the secret entirely for AKS workloads.

**Assigning Application permissions at broad resource scope**: Application permissions in Entra ID often apply to all resources of a type (e.g., all mailboxes, all sites). Where the API supports it, use resource-specific consent (RSC) to scope to specific resources.

**Managed Identity with no resource scope**: Assigning `Contributor` at subscription level to a Managed Identity for "convenience" is the Azure equivalent of `roles/editor` project-level bindings in GCP. Grant at the resource group or resource level.

**Not enabling OIDC Issuer on AKS before configuring Azure Workload Identity**: The cluster must have `oidcIssuerProfile.enabled: true`. Enabling it after the fact requires updating the cluster, which takes several minutes and may trigger a node pool operation.

---

## References

- [Azure: Managed Identity Overview](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview)
- [Azure: Workload Identity for AKS](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
- [Azure: Federated Identity Credentials](https://learn.microsoft.com/en-us/graph/api/resources/federatedidentitycredential)
- [Azure: Entra ID SCIM Provisioning](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/user-provisioning)
- [Azure: Conditional Access for Workload Identities](https://learn.microsoft.com/en-us/entra/identity/conditional-access/workload-identity)
