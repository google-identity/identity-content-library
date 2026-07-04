# Okta as External IdP for GCP and AWS

**Last updated:** 2026-07-04

This guide covers using Okta as the authoritative identity provider for both Google Cloud Platform and AWS. The pattern: Okta issues OIDC or SAML tokens; each cloud validates those tokens and maps them to cloud-native permissions.

---

## The Architecture

```
Users / Workloads
       │
       │  Authenticate to Okta
       ▼
  Okta (IdP)
  ├── Issues OIDC ID token (for OIDC federation)
  └── Issues SAML assertion (for SAML federation)
       │
       ├──────────────────────────────────┐
       ▼                                  ▼
  GCP (WIF OIDC provider)           AWS (IAM OIDC/SAML provider)
  Maps Okta claims → GCP identity   Maps Okta claims → IAM role
       │                                  │
       ▼                                  ▼
  GCP resources                     AWS resources
```

For human users, both GCP and AWS support SAML-based SSO from Okta via their respective SSO configurations. For machine-to-machine (workloads), the pattern is OIDC: Okta issues an ID token; the cloud validates the token against the registered Okta OIDC provider.

---

## Part 1: Okta → GCP via Workload Identity Federation

### Step 1: Configure an Okta OIDC Application

In the Okta Admin Console:

1. **Applications → Create App Integration**
2. Select **OIDC - OpenID Connect**, then **Web Application** (for user federation) or **API Services** (for M2M)
3. For **Grant type**: select **Authorization Code** (users) or **Client Credentials** (M2M)
4. Set **Redirect URIs** if this is for user SSO — not needed for pure M2M
5. Note the **Client ID** and **Okta domain** (e.g., `https://mycompany.okta.com`)

For groups-based access control, ensure **Groups claim** is included in the ID token:
- Go to the application's **Sign On** tab → **Edit** → **OpenID Connect ID Token**
- Add a **Groups claim**: Filter `matches regex` → `.*` (or a specific group prefix)

### Step 2: Create the WIF Pool and Provider (Terraform)

```hcl
resource "google_iam_workload_identity_pool" "okta_pool" {
  workload_identity_pool_id = "okta-federation"
  display_name              = "Okta Federation"
  description               = "WIF pool for Okta-authenticated users and services"
  project                   = var.project_id
}

resource "google_iam_workload_identity_pool_provider" "okta_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.okta_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "okta-oidc"
  project                            = var.project_id
  display_name                       = "Okta OIDC"

  attribute_mapping = {
    # Map Okta claims to GCP attributes
    "google.subject"    = "assertion.sub"
    "attribute.email"   = "assertion.email"
    "attribute.groups"  = "assertion.groups"
    "attribute.login"   = "assertion.preferred_username"
  }

  # Only allow tokens from your Okta org's client ID
  attribute_condition = "assertion.iss == 'https://${var.okta_domain}' && '${var.okta_client_id}' in assertion.aud"

  oidc {
    issuer_uri        = "https://${var.okta_domain}"
    allowed_audiences = [var.okta_client_id]
  }
}
```

**Critical:** The `attribute_condition` must validate both the issuer (`iss`) AND the audience (`aud`). Validating only the issuer means any Okta client in your org could authenticate. Validating only the audience is insufficient if your Okta domain is multi-tenant.

### Step 3: Bind GCP Permissions

**Option A: Bind directly to a WIF principal (no service account)**

```bash
# Grant specific Okta group access to a bucket
gcloud storage buckets add-iam-policy-binding gs://my-bucket \
  --member="principalSet://iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/okta-federation/attribute.groups/gcp-data-readers" \
  --role="roles/storage.objectViewer"
```

**Option B: Okta user impersonates a GCP service account**

```hcl
resource "google_service_account_iam_binding" "okta_impersonation" {
  service_account_id = google_service_account.data_pipeline_sa.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    # Allow any Okta user in the 'data-engineers' group
    "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.okta_pool.name}/attribute.groups/data-engineers"
  ]
}
```

### Step 4: Exchange Okta Token for GCP Credential

In your application:

```python
import google.auth
from google.auth import impersonated_credentials
from google.oauth2 import service_account
import google.auth.transport.requests

def get_gcp_token_from_okta(okta_id_token: str, project_number: str, pool_id: str, provider_id: str) -> str:
    """Exchange an Okta OIDC token for a GCP access token via WIF."""
    import requests

    # Step 1: Exchange Okta token for GCP federated token
    sts_response = requests.post(
        "https://sts.googleapis.com/v1/token",
        json={
            "audience": f"//iam.googleapis.com/projects/{project_number}/locations/global/workloadIdentityPools/{pool_id}/providers/{provider_id}",
            "grantType": "urn:ietf:params:oauth:grant-type:token-exchange",
            "requestedTokenType": "urn:ietf:params:oauth:token-type:access_token",
            "scope": "https://www.googleapis.com/auth/cloud-platform",
            "subjectTokenType": "urn:ietf:params:oauth:token-type:id_token",
            "subjectToken": okta_id_token,
        }
    )
    sts_response.raise_for_status()
    return sts_response.json()["access_token"]
```

In practice, use the `google-auth` library's Application Default Credentials with a credential configuration file — this handles the exchange automatically.

### Credential Configuration File (for ADC)

```json
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/okta-federation/providers/okta-oidc",
  "subject_token_type": "urn:ietf:params:oauth:token-type:id_token",
  "token_url": "https://sts.googleapis.com/v1/token",
  "credential_source": {
    "file": "/var/run/okta-token",
    "format": {
      "type": "text"
    }
  }
}
```

Your application writes the Okta ID token to `/var/run/okta-token`; the GCP SDK handles the STS exchange transparently.

---

## Part 2: Okta → AWS via IAM OIDC Federation

AWS supports two Okta federation patterns:
1. **SAML** — for AWS Console SSO (the classic pattern)
2. **OIDC** — for programmatic access (recommended for workloads)

### SAML Federation (Console SSO)

This is well-documented by both Okta and AWS. The short version:

1. In Okta: Create a SAML 2.0 app integration for AWS
2. Download the IdP metadata XML from Okta
3. In AWS: Create an IAM SAML identity provider using the metadata XML
4. Create IAM roles with the SAML provider as the trusted principal
5. Map Okta groups to AWS roles via the SAML attribute `https://aws.amazon.com/SAML/Attributes/Role`

**Limitation of SAML for workloads:** SAML involves browser redirects and is not suitable for non-interactive workloads. Use OIDC for programmatic access.

### OIDC Federation for Workloads (Terraform)

```hcl
# Register Okta as an OIDC identity provider in AWS
resource "aws_iam_openid_connect_provider" "okta" {
  url = "https://${var.okta_domain}"

  client_id_list = [
    var.okta_client_id,
  ]

  # Okta's OIDC certificate thumbprint
  # Get this with: openssl s_client -connect OKTA_DOMAIN:443 | openssl x509 -fingerprint -sha1
  # Or use the value below (valid for Okta's default TLS cert as of 2026)
  thumbprint_list = [var.okta_thumbprint]
}

# IAM role that Okta users can assume
resource "aws_iam_role" "okta_federated" {
  name = "okta-data-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.okta.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.okta_domain}:aud" = var.okta_client_id
          }
          # Optionally: restrict to specific Okta groups claim
          StringLike = {
            "${var.okta_domain}:groups" = "aws-data-readers"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "okta_federated_s3_read" {
  role       = aws_iam_role.okta_federated.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}
```

### Programmatic Token Exchange (Python)

```python
import boto3
import requests

def get_aws_credentials_from_okta(okta_id_token: str, role_arn: str) -> dict:
    """Exchange an Okta OIDC token for temporary AWS credentials."""
    sts = boto3.client("sts")
    
    response = sts.assume_role_with_web_identity(
        RoleArn=role_arn,
        RoleSessionName="okta-federated-session",
        WebIdentityToken=okta_id_token,
        DurationSeconds=3600,
    )
    
    return response["Credentials"]
```

---

## Group-Based Access Control

Both GCP and AWS support mapping Okta group membership to cloud permissions. The mechanics differ.

**GCP (via WIF attribute mapping):**
- Include `groups` in the Okta ID token (configure the groups claim in the Okta app)
- Map `assertion.groups` to a GCP attribute in the WIF provider
- Bind GCP roles to `principalSet:///attribute.groups/group-name`

**AWS (via SAML attribute or OIDC condition):**
- For SAML: map Okta groups to the AWS role attribute in the SAML assertion
- For OIDC: include groups in the Okta ID token; use a `Condition` in the IAM role trust policy to restrict `AssumeRoleWithWebIdentity` to specific group values

**Okta groups → multiple IAM roles:** Each IAM role has its own trust policy with its own group condition. Users with multiple groups can assume multiple roles. For console SSO, the Okta SAML attribute maps multiple roles in one assertion.

---

## Session Duration Considerations

| Scenario | Default | Max | Notes |
|----------|---------|-----|-------|
| GCP WIF federated token | 1 hour | 1 hour | Set in WIF provider `access_token_lifetime` |
| GCP SA impersonation via WIF | 1 hour | 12 hours (with constraints) | `serviceAccountTokenCreator` impersonation limit |
| AWS STS via OIDC | 1 hour | 12 hours | Set `DurationSeconds` in AssumeRoleWithWebIdentity |
| AWS SAML federation | 1 hour | 12 hours | Set `DurationSeconds` in AssumeRoleWithSAML |
| Okta session | 2 hours (default) | Configurable | Controlled in Okta global session policy |

**Important:** GCP WIF tokens are non-refreshable — when they expire, the workload must obtain a new Okta token and re-exchange. Design workloads to re-authenticate before expiry; don't assume the token is long-lived.

---

## Security Recommendations

1. **Validate both `iss` and `aud` in WIF attribute conditions.** An Okta token from a different Okta application in the same org should not be able to authenticate.

2. **Use groups, not individual user subjects, for access bindings.** Subject (`sub`) values in Okta are stable UUIDs, but binding per-user is maintenance overhead. Use group membership.

3. **Enable Okta's token binding** (where supported) to prevent token replay attacks across network contexts.

4. **Set explicit session policies** in the Okta org: require MFA before issuing tokens used for cloud access.

5. **Audit Okta → cloud token exchanges** in your SIEM. Look for: unexpected Okta clients in the `aud` claim, users exchanging tokens outside business hours, and unusually high exchange rates (may indicate automation misuse).

---

## References

- [WIF with OIDC providers](https://cloud.google.com/iam/docs/workload-identity-federation-with-other-providers) — GCP docs
- [AWS OIDC identity providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html) — AWS docs
- [Okta: Configure OIDC for GCP](https://developer.okta.com/docs/) — Okta developer docs (search "Google Cloud Platform")
- [Okta: AWS SAML integration](https://saml-doc.okta.com/SAML_Docs/How-to-Configure-SAML-2.0-for-Amazon-Web-Service.html) — Okta SAML docs
