# Conference CFP Targets and Speaker Proposals

**Prepared:** 2026-07-04  
**Status:** Drafts ready for CEO review before submission

---

## CFP Opportunities Identified

### Priority 1: Must Submit

| Conference | Dates | CFP Deadline | Topic Fit | Status |
|-----------|-------|--------------|-----------|--------|
| **Google Cloud Next 2027** | April 2027 | ~October 2026 | Primary — GCP identity is our core content | CFP opens ~Sep 2026; prep now |
| **KubeCon NA 2026** | Nov 2026, Atlanta | ~June 2026 | High — security track, SPIFFE/WIF for K8s | **CFP likely closed** — target 2027 |
| **KubeCon EU 2027** | March 2027 | ~October 2026 | High — same as above | Prep now |

### Priority 2: Strong Fit

| Conference | Dates | CFP Deadline | Topic Fit | Status |
|-----------|-------|--------------|-----------|--------|
| **Identity Week** (London) | June 2027 | ~Jan 2027 | High — identity-native audience | Track for CFP |
| **IIW (Internet Identity Workshop)** | Oct/April (unconference) | No CFP — show up | Very high — practitioners, OIDC/OAuth/FIDO | Attend next session |
| **SANS CloudSecNext** | TBD 2027 | TBD | High — cloud security practitioners | Track |
| **RSA Conference 2027** | April/May 2027 | ~October 2026 | Medium — identity is one track among many | Submit to Cloud Security track |
| **fwd:cloudsec** | Summer 2027 | TBD | High — practitioner security, cloud-native | Excellent fit for opinionated cross-cloud content |

### Priority 3: Watch List

| Conference | Notes |
|-----------|-------|
| **GCP User Groups** (regional) | Low-effort, high-visibility for GCP practitioners. Target SF, NYC, London groups. |
| **AWS re:Inforce** | Security focus; submit WIF/cross-cloud talk to Identity track |
| **Microsoft Ignite** | Submit Azure → GCP WIF example if cross-cloud angle is developed further |

---

## Proposal 1: Eliminate Service Account Keys Forever — A WIF Migration Playbook

**Target conferences:** Google Cloud Next 2027, SANS CloudSecNext, fwd:cloudsec

### Abstract (300 words)

Service account key leakage is the #1 identity-related incident in GCP environments. Organizations know keys are bad; they keep creating them anyway because the migration path to Workload Identity Federation looks daunting. It isn't — and this talk is the playbook.

We'll cover the full WIF migration lifecycle: auditing your key inventory with Cloud Asset Inventory, mapping each key-using workload to its WIF equivalent (AWS IAM role, Azure Managed Identity, GitHub Actions, GKE Workload Identity), running key and keyless authentication in parallel during migration, and enforcing the `iam.disableServiceAccountKeyCreation` org policy as the final gate.

By the end of this session, you'll have:
- A prioritization framework for which workloads to migrate first (by blast radius, not convenience)
- Working Terraform and gcloud commands for each WIF provider type
- A testing strategy that validates keyless auth before disabling keys
- A governance model: org policy constraints plus IAM Recommender for ongoing hygiene

This is not a WIF feature overview. We assume you know WIF exists. This talk is about how to actually get it done in a real organization with legacy workloads, multiple teams, and a security team that wants keys gone yesterday.

### Format: 40-minute talk + 5-minute Q&A

### Speaker bio note
*Google Cloud Identity produces authoritative cross-cloud identity architecture references. We've catalogued WIF migration patterns across AWS, Azure, GitHub Actions, and GKE environments.*

---

## Proposal 2: Cross-Cloud Identity Without Keys: AWS, Azure, and GitHub Actions Authenticating to GCP

**Target conferences:** KubeCon EU 2027, Google Cloud Next 2027, Identity Week

### Abstract (300 words)

Multi-cloud deployments have a dirty secret: most organizations still use service account keys to let AWS Lambdas and GitHub Actions pipelines call GCP APIs. These long-lived credentials are a compliance liability and a breach waiting to happen.

Workload Identity Federation eliminates this entirely. An AWS Lambda can authenticate to GCP using nothing but its IAM role identity — no key file, no secret, no rotation schedule. An Azure workload uses its Managed Identity OIDC token. A GitHub Actions workflow uses its ephemeral OIDC JWT. GCP validates each of these and issues a short-lived token scoped to exactly the right permissions.

This talk walks through each pattern in depth:

**AWS → GCP:** How WIF's AWS provider uses SigV4 signing to validate AWS identity. What the attribute mapping looks like. How to restrict to specific IAM roles, not just AWS accounts. Common mistakes in the trust chain.

**Azure → GCP:** Using Managed Identity OIDC tokens with WIF. The difference between system-assigned and user-assigned managed identities and which to use. Federated credential configuration on the Azure side.

**GitHub Actions → GCP:** The OIDC token GitHub issues per-workflow, per-repo, per-branch. How to write WIF attribute conditions that lock down access to specific repos and branches. The ref vs. repository_owner distinction that most tutorials get wrong.

Each section includes working Terraform, the token flow diagram, and the exact gcloud commands to validate the setup. We close with a governance pattern: one WIF pool per environment, one provider per external source, attribute conditions that are strict-by-default.

### Format: 40-minute talk + 5-minute Q&A, or 25-minute lightning slot

### Session type: Technical deep-dive (300-level)

---

## Submission Notes for CEO Review

Both proposals are ready for submission to Google Cloud Next 2027 (CFP expected ~September 2026) and KubeCon EU 2027.

**Action required before submission:**
1. CEO review and approval of both abstracts
2. Speaker name and title finalization
3. Company profile / bio for submission forms

Per the boundaries in my role, I will not submit these without explicit CEO approval. Please comment on this issue with approval or requested changes.
