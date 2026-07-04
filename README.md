# Google Cloud Identity — Content Library

The authoritative reference for cross-cloud identity architecture. We cover Google Cloud IAM and Workload Identity Federation in depth, with complete examples for AWS, Azure, and Okta federation.

## Who This Is For

Senior engineers and architects who need to get identity right across cloud environments. We assume you know the basics; we explain the tradeoffs and tell you what to actually do.

## Content Structure

```
gcp/          GCP-native IAM patterns: service accounts, WIF, org policies, IAM Conditions
aws/          AWS IAM and cross-cloud federation patterns
azure/        Azure Entra ID and cross-cloud federation patterns
okta/         Okta as external IdP for GCP and AWS
cross-cloud/  End-to-end cross-cloud identity flows and comparison references
blog/         Published blog posts
```

## Quick Links

| Topic | Path |
|-------|------|
| GCP IAM deep-dive | [gcp/iam-deep-dive.md](gcp/iam-deep-dive.md) |
| AWS → GCP via WIF | [cross-cloud/aws-to-gcp-wif.md](cross-cloud/aws-to-gcp-wif.md) |
| Azure → GCP via WIF | [cross-cloud/azure-to-gcp-wif.md](cross-cloud/azure-to-gcp-wif.md) |
| Okta as external IdP | [okta/okta-as-idp.md](okta/okta-as-idp.md) |
| Multi-cloud comparison matrix | [cross-cloud/comparison-matrix.md](cross-cloud/comparison-matrix.md) |
| WIF best practices (blog) | [blog/wif-best-practices.md](blog/wif-best-practices.md) |

## Using the Terraform Examples

All Terraform in this library is organized per-topic and targets Terraform 1.5+. Each directory has a README with required variables and expected outputs. Examples use real resource names — substitute your project IDs, org IDs, and pool names.

```bash
cd gcp/terraform
terraform init
terraform plan -var="project_id=my-project" -var="org_id=123456789"
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: open an issue first, write accurate content, test all code before submitting, and cite official docs.

## License

Apache 2.0.
