# AWS IAM Patterns for Identity Engineers

**Audience:** Engineers working with AWS IAM, especially those integrating AWS workloads with GCP or managing cross-account identity patterns.

**Last updated:** 2026-07-04

---

## AWS Machine Identity Primitives

AWS workload identity is built on IAM Roles and the Security Token Service (STS). The key insight: **roles are not long-lived credentials**, they're permission sets that generate short-lived tokens on demand.

| Identity Type | Use Case | Credential Lifetime |
|--------------|----------|---------------------|
| IAM Role (EC2 instance profile) | EC2, ECS tasks | 1-6 hours (auto-refreshed) |
| IAM Role (Lambda execution) | Lambda functions | Up to 12 hours |
| EKS Pod Identity / IRSA | Kubernetes pods | 1 hour (IRSA), configurable (Pod Identity) |
| IAM Role (GitHub Actions OIDC) | CI/CD pipelines | 1 hour |
| IAM User access keys | Legacy; avoid for workloads | Until manually rotated |

**The rule:** No workload should use IAM User credentials or hardcoded access keys. Use IAM Roles attached to the compute resource or OIDC federation for CI/CD.

---

## IRSA vs EKS Pod Identity

Two mechanisms exist for giving Kubernetes pods an AWS identity. Pod Identity is the newer and simpler one.

### IRSA (IAM Roles for Service Accounts)

IRSA works by:
1. Your EKS cluster has an OIDC issuer URL
2. You register that OIDC issuer as a trusted identity provider in IAM
3. Kubernetes projects a signed OIDC token into the pod's filesystem
4. The AWS SDK calls `sts:AssumeRoleWithWebIdentity` using that token

```bash
# The token is available at:
/var/run/secrets/eks.amazonaws.com/serviceaccount/token

# AWS SDK env vars (set automatically by EKS when IRSA is configured):
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/my-app-role
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

IRSA is mature and widely supported. Its limitation: the trust policy references the OIDC issuer and the Kubernetes service account namespace + name, which couples IAM role configuration to cluster-specific details.

### EKS Pod Identity (recommended for new clusters)

Pod Identity (launched 2023) is simpler:
- No OIDC provider setup in IAM
- IAM role associations are managed in EKS, not in IAM trust policies
- Works across clusters without per-cluster IAM configuration
- Handles credential refresh via a Pod Identity agent daemonset

```bash
# Associate a role with a service account
aws eks create-pod-identity-association \
  --cluster-name my-cluster \
  --namespace production \
  --service-account my-app \
  --role-arn arn:aws:iam::123456789012:role/my-app-role
```

Pod Identity is now the recommended approach for new EKS clusters. Use IRSA if you're on an older cluster or integrating with tools that have hard-coded IRSA assumptions.

---

## Cross-Account Access Patterns

The standard pattern for cross-account access in AWS:

```
Account A (workload) → AssumeRole → Account B (resources)
```

The role in Account B has a trust policy that allows Account A to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::ACCOUNT-A:role/my-workload-role"
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {
        "sts:ExternalId": "unique-external-id"
      }
    }
  }]
}
```

The `ExternalId` condition prevents the [confused deputy problem](https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html) — a third party can't trick your account into assuming a role by knowing the role ARN. Generate a random external ID per customer or integration and treat it as a secret.

---

## SCPs vs IAM Policies

Service Control Policies (SCPs) are often misunderstood. Key points:

**SCPs are ceiling setters, not permission granters.** An SCP that allows `s3:GetObject` doesn't grant access — the IAM policy must also allow it. SCPs define the maximum permissions that can be granted; identity policies within the account define what's actually granted.

**SCPs apply to all principals in the account** including the root user. This is the mechanism for org-wide guardrails: prevent disabling CloudTrail, prevent leaving a specific region, prevent creating IAM users.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyIAMUserCreation",
    "Effect": "Deny",
    "Action": "iam:CreateUser",
    "Resource": "*",
    "Condition": {
      "StringNotEquals": {
        "aws:PrincipalARN": "arn:aws:iam::*:role/BreakGlassRole"
      }
    }
  }]
}
```

This pattern denies IAM user creation to everyone except the break-glass role — a common guardrail in organizations migrating to IAM Identity Center.

---

## IAM Identity Center (SSO) vs Federated IAM Roles

For human access to AWS, use IAM Identity Center. It provides:
- Central identity management (SAML, SCIM, or native users)
- Permission sets that deploy as IAM roles across accounts
- Audit trail for console and CLI access
- Session durations configurable per permission set

The alternative — configuring SAML federation directly in IAM per account — works but doesn't scale. IAM Identity Center is the managed version of the same thing.

For non-human workloads: IAM Identity Center is irrelevant. Use IAM Roles.

---

## Permission Boundaries

Permission boundaries set the maximum permissions an identity can grant when creating roles or policies. They're a delegation mechanism, not a security boundary you apply to your own workloads.

Use case: you want to let an application team manage their own IAM roles without being able to create roles that exceed their own permissions (privilege escalation via IAM).

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "iam:CreateRole",
    "Resource": "*",
    "Condition": {
      "StringEquals": {
        "iam:PermissionsBoundary": "arn:aws:iam::123456789012:policy/TeamBoundary"
      }
    }
  }]
}
```

This requires any role the team creates to have the boundary policy attached. The boundary policy limits what any role in the team can do, regardless of what other policies are attached.

---

## Audit and Observability

**CloudTrail** records every IAM API call and most service API calls. The `userIdentity` field shows who made the call:

```json
"userIdentity": {
  "type": "AssumedRole",
  "principalId": "AROAEXAMPLEID:session-name",
  "arn": "arn:aws:sts::123456789012:assumed-role/my-role/session-name",
  "accountId": "123456789012",
  "sessionContext": {
    "sessionIssuer": {
      "type": "Role",
      "arn": "arn:aws:iam::123456789012:role/my-role"
    }
  }
}
```

For GCP WIF → AWS cross-cloud flows, the CloudTrail entry records `GetCallerIdentity` calls from GCP's STS service. You can filter for these to audit all GCP→AWS identity exchanges.

**IAM Access Analyzer** identifies resources in your account accessible from outside the account. Run it on new accounts; alert on new external findings.

---

## References

- [AWS: IAM Roles Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [AWS: EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)
- [AWS: IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [AWS: SCPs](https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html)
- [AWS: IAM Identity Center](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html)
