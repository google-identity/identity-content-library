# Multi-Cloud Identity Comparison Matrix

**Last updated:** 2026-07-04

This is a reference for engineers making architectural decisions about identity across GCP, AWS, Azure, and Okta. Where vendor documentation is silent or misleading, we say so.

---

## 1. Workload / Machine Identity Primitives

| Dimension | GCP | AWS | Azure | Okta |
|-----------|-----|-----|-------|------|
| **Native machine identity** | Service Account | IAM Role (attached to EC2/Lambda/ECS) | Managed Identity (System- or User-Assigned) | Machine-to-Machine via OAuth 2.0 Client Credentials |
| **Identity lifecycle** | Per-project SA, long-lived | Role assumed per-request, short-lived STS tokens | Per-resource or shared identity | Client ID + secret or certificate, long-lived |
| **Key-based credential** | SA key (JSON) — avoid | Access key + secret — avoid | App registration secret/certificate — avoid for workloads | Client secret — required for M2M, rotate frequently |
| **Keyless credential** | WIF + OIDC/AWS/Azure | STS AssumeRoleWithWebIdentity | Managed Identity (no credential needed) | OIDC federation (receive external tokens) |
| **Token lifetime** | 1 hour (SA access token), 1 hour (WIF STS) | 15 min–12 hours (STS), 1 hour (EC2 metadata) | 1 hour | 1 hour (configurable per-policy) |
| **Automatic rotation** | Yes (via metadata server / WIF) | Yes (via metadata server) | Yes (Managed Identity) | No for secrets; yes for certificate-based |

**Bottom line:** GCP and AWS both push you toward keyless identity for workloads. Azure Managed Identity is the most seamless — no configuration required on properly-configured Azure resources. Okta M2M is still credential-based and requires rotation discipline.

---

## 2. Federation Protocols Supported

| Dimension | GCP | AWS | Azure | Okta |
|-----------|-----|-----|-------|------|
| **OIDC (inbound)** | Yes — WIF OIDC provider | Yes — IAM OIDC identity provider | Yes — Entra External Identities / Federated Credentials | Yes — as relying party |
| **SAML 2.0 (inbound)** | Yes — Cloud Identity SSO | Yes — IAM SAML identity provider | Yes — Entra ID SSO | Yes — as IdP and SP |
| **OIDC (outbound, issuing tokens)** | Yes — WIF issues GCP OIDC tokens | Yes — STS issues STS tokens (not standard OIDC) | Yes — Managed Identity issues OIDC tokens | Yes — Okta is an OIDC IdP |
| **SPIFFE/SPIRE** | Partial — via GKE Workload Identity | Partial — via EKS + IRSA | Partial — via AKS + AAD Pod Identity | No native support |
| **AWS IAM auth (inbound)** | Yes — WIF AWS provider | N/A | No native | No native |
| **X.509 / mTLS** | Via Certificate Authority Service | Via ACM Private CA | Via Entra Certificate-Based Auth | Yes — smart card / PIV |

**Note on SPIFFE:** GKE, EKS, and AKS all have integrations that look like SPIFFE/SPIRE but none implement the full SPIFFE spec. Dedicated SPIRE deployments are the only way to get true cross-cloud SPIFFE identity today.

---

## 3. Cross-Cloud Authentication

| Flow | GCP | AWS | Azure | Okta |
|------|-----|-----|-------|------|
| **AWS → GCP** | WIF AWS provider (uses SigV4 signing) | Source: IAM role | — | — |
| **Azure → GCP** | WIF OIDC provider (Managed Identity issues OIDC token) | — | Source: Managed Identity | — |
| **GitHub Actions → GCP** | WIF OIDC provider | OIDC → STS | Federated credential | — |
| **GitHub Actions → AWS** | — | OIDC → STS | — | — |
| **GCP → AWS** | SA or WIF token | AssumeRoleWithWebIdentity | — | — |
| **Okta → GCP** | WIF OIDC provider | — | — | Source: Okta OIDC |
| **Okta → AWS** | — | IAM OIDC provider | — | Source: Okta SAML/OIDC |
| **Okta → Azure** | — | — | Entra External Identities | Source: Okta SAML/OIDC |

**Cross-cloud auth is OIDC all the way down.** Any system that can issue OIDC JWTs can authenticate to GCP WIF, AWS STS (with OIDC provider), or Azure Federated Credentials. The differentiator is how well each cloud validates those tokens and what attribute conditions you can express.

---

## 4. Policy Languages

| Dimension | GCP | AWS | Azure | Okta |
|-----------|-----|-----|-------|------|
| **Policy format** | JSON (IAM bindings + conditions) | JSON (IAM policies, SCP, resource policies) | JSON (RBAC role assignments + Azure Policy) | JSON (okta policy rules) |
| **Condition language** | CEL (Common Expression Language) | IAM condition keys (AWS-specific syntax) | Azure Policy condition language | Expression language (limited) |
| **Attribute-based access** | IAM Conditions (CEL) | ABAC via tags + condition keys | Azure ABAC (preview/GA for storage) | Group-based + custom expressions |
| **Resource-level policies** | Yes — most resources support IAM policies | Yes — S3, KMS, SQS, etc. have resource policies | Yes — resource-level RBAC | N/A (Okta is IdP, not resource owner) |
| **Hierarchical policies** | Org → Folder → Project → Resource | Org SCPs → Account → Resource | Management Group → Subscription → Resource Group → Resource | Org → Group → User |
| **Deny policies** | Yes — IAM Deny policies (newer feature) | Yes — explicit Deny in policy | Yes — Azure Policy deny effects | N/A |

**GCP's CEL is the most expressive condition language.** AWS condition keys are powerful but require memorizing provider-specific key names. Azure ABAC is still maturing. If you need complex ABAC across clouds, consider centralizing policy in a system like OPA/Styra and pushing decisions to each cloud via admission webhooks or lambda authorizers.

---

## 5. Audit Logging

| Dimension | GCP | AWS | Azure | Okta |
|-----------|-----|-----|-------|------|
| **Always-on audit log** | Admin Activity (immutable) | CloudTrail management events | Azure Activity Log | Okta System Log |
| **Data access logging** | Optional (Data Access audit logs) | Optional (S3 data events, etc.) | Optional (resource diagnostic settings) | Always on for auth events |
| **Log retention (default)** | 400 days (Admin Activity) | 90 days (CloudTrail), indefinite in S3 | 90 days (Activity Log), configurable in Log Analytics | 90 days |
| **Log immutability** | Admin Activity logs are immutable; Data Access can be filtered | CloudTrail log validation (SHA-256 digest) | Activity logs immutable for 90 days | Yes — System Log is immutable |
| **Real-time export** | Pub/Sub sink | EventBridge / CloudWatch | Event Hub / Sentinel | Syslog / SIEM integration |
| **IAM-specific events** | `SetIamPolicy`, `CreateServiceAccountKey`, `GenerateAccessToken` | `AssumeRole`, `CreateAccessKey`, `AttachRolePolicy` | `Add member to role`, `Create app registration` | `user.session.start`, `group.user.add` |

**Recommendation:** Export all cloud audit logs to a single SIEM (Splunk, Chronicle, Sentinel). GCP's Cloud Audit Logs → Chronicle is the most integrated path if you're GCP-primary.

---

## 6. Key Management Integration

| Dimension | GCP | AWS | Azure | Okta |
|-----------|-----|-----|-------|------|
| **Managed KMS** | Cloud KMS | AWS KMS | Azure Key Vault | N/A (uses Google/AWS for key storage) |
| **HSM support** | Cloud HSM (FIPS 140-2 Level 3) | AWS CloudHSM | Dedicated HSM | N/A |
| **Customer-managed keys (CMK)** | CMEK on most GCP services | SSE-KMS on most AWS services | Customer-managed keys in Key Vault | N/A |
| **Secret management** | Secret Manager | Secrets Manager | Key Vault Secrets | N/A |
| **Key rotation** | Automatic (configurable) | Automatic annual rotation (optional) | Automatic (configurable) | Client secret must be rotated manually |
| **Cross-cloud KMS** | Via EKMS (external key manager) | Via XKS (external key store) | Via Bring Your Own Key (BYOK) | N/A |

---

## 7. Summary: When to Use What

| Scenario | Recommendation |
|----------|----------------|
| Human users authenticating to GCP | Cloud Identity + SSO; federate to Okta if you have a centralized IdP |
| CI/CD pipeline (GitHub Actions) authenticating to GCP | WIF OIDC provider — no keys needed |
| AWS Lambda calling GCP APIs | WIF AWS provider — use SigV4, no keys |
| Azure workload calling GCP APIs | WIF OIDC provider + Managed Identity — no keys |
| GKE workload calling GCP APIs | GKE Workload Identity — annotate KSA, done |
| Cross-cloud secrets synchronization | Don't. Use native secrets manager per-cloud; access secrets via short-lived tokens |
| Policy enforcement across all clouds | OPA/Styra for unified policy; each cloud evaluates locally |
| Centralized user IdP | Okta or Entra ID as upstream; federate into each cloud via SAML or OIDC |

---

## References

- [GCP IAM overview](https://cloud.google.com/iam/docs/overview)
- [AWS IAM overview](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction.html)
- [Azure RBAC overview](https://learn.microsoft.com/en-us/azure/role-based-access-control/overview)
- [Okta Developer Docs](https://developer.okta.com/docs/)
- [SPIFFE specification](https://spiffe.io/docs/latest/spiffe-about/overview/)
- [OIDC specification](https://openid.net/connect/)
