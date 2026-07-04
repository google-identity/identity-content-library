# AWS Identity Patterns

This section covers AWS IAM patterns and cross-cloud federation from AWS to Google Cloud.

## Contents

| Topic | Path |
|-------|------|
| AWS to GCP via WIF (full example) | [../cross-cloud/aws-to-gcp-wif.md](../cross-cloud/aws-to-gcp-wif.md) |
| WIF best practices (blog) | [../blog/wif-best-practices.md](../blog/wif-best-practices.md) |

## AWS IAM Fundamentals for Cross-Cloud Work

AWS workloads use IAM roles — not long-lived credentials — to authenticate to AWS services. When federating to Google Cloud via Workload Identity Federation, the same IAM role serves as the identity anchor.

### Key AWS Identity Primitives

- **IAM Role**: The primary identity for workloads. EC2 instance profiles, ECS task roles, Lambda execution roles, and EKS IRSA all attach an IAM role to a compute resource.
- **STS (Security Token Service)**: Issues short-lived credentials. When an EC2 instance uses its instance profile, it's calling STS `AssumeRole` internally.
- **IAM Identity Center (formerly SSO)**: Federation for human users. Separate from workload identity — don't conflate them.

### How AWS Workload Identity Works with WIF

When an AWS workload authenticates to GCP using Workload Identity Federation:

1. The AWS workload calls STS to get its current credentials (this happens automatically via the instance metadata service or SDK).
2. The GCP client library uses these AWS credentials to sign an STS `GetCallerIdentity` request.
3. Google Cloud STS verifies the signed request with AWS STS, establishing that the caller holds a specific IAM role ARN.
4. Google Cloud issues a federated token scoped to the matching Workload Identity Pool principal.

The key is step 3: Google doesn't trust AWS JWT tokens directly. It trusts the signed request format — which only a holder of valid AWS credentials can produce.

### IAM Role Configuration

For cross-cloud federation, your AWS IAM role needs no special trust policy modifications for the GCP side — the WIF configuration lives entirely in GCP. However, the role must have a trust policy that allows the compute service to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

For ECS Fargate tasks:
```json
{
  "Principal": {
    "Service": "ecs-tasks.amazonaws.com"
  }
}
```

For Lambda:
```json
{
  "Principal": {
    "Service": "lambda.amazonaws.com"
  }
}
```

### Terraform Examples

See [`../cross-cloud/aws-to-gcp-wif.md`](../cross-cloud/aws-to-gcp-wif.md) for complete Terraform covering both the AWS IAM role and the GCP WIF configuration.

## Best Practices

**Least privilege on the AWS side**: The IAM role permissions should be scoped to only what the workload needs in AWS. Don't conflate AWS permissions with GCP permissions — they're independent.

**Separate roles per environment**: Use distinct IAM roles for dev/staging/prod. This way, a WIF attribute condition scoped to a role ARN gives you clean environment isolation.

**No access keys**: If you're setting up cross-cloud federation, you're doing it to avoid long-lived credentials. Don't also add IAM access keys to the same account for the same workload.

**Monitor CloudTrail**: AWS CloudTrail logs the STS `GetCallerIdentity` calls that WIF makes. These appear in your CloudTrail as calls from the `sts.amazonaws.com` service. An unusual spike indicates either a misconfigured retry loop or unexpected token exchange activity.
