# Contributing to the Google Cloud Identity Content Library

## Before You Start

Open an issue describing what you want to add or fix. This avoids duplicate work and lets us discuss the right scope before you write anything.

## Content Standards

**Accuracy is non-negotiable.** If you're not sure about a behavior, test it in a real environment. If vendor documentation contradicts what you observe, say so explicitly and cite both.

**Be opinionated.** "Here are five ways to do X" is less useful than "Do X this way, here's why, and here's when you'd deviate." If there's a clear best practice, state it.

**Code must run.** All Terraform, gcloud commands, and scripts must be tested against real infrastructure before submission. If you can't test something, mark it clearly as untested.

**Cite official documentation.** Every non-obvious claim should link to the authoritative source. Flag when docs are incomplete or misleading — this is genuinely useful signal.

## Directory Conventions

- Provider-specific content lives under the provider directory (`gcp/`, `aws/`, `azure/`, `okta/`)
- Cross-provider examples go in `cross-cloud/`
- Blog posts go in `blog/` with a `YYYY-MM-` prefix
- Each Terraform example lives in its own subdirectory with a `README.md`, `main.tf`, `variables.tf`, and `outputs.tf`

## Terraform Style

- Use `google`, `aws`, `azurerm`, `okta` provider aliases as-is — no custom wrappers
- Pin provider versions; use `~>` constraints
- All variables must have descriptions
- Sensitive outputs must be marked `sensitive = true`
- No hardcoded project IDs, org IDs, or credentials

## Review Checklist

Before submitting a PR:

- [ ] All code tested against real infrastructure
- [ ] Official docs cited for non-obvious claims
- [ ] No hardcoded credentials or project identifiers
- [ ] Terraform validates cleanly (`terraform validate`)
- [ ] Markdown renders correctly (check headers, code blocks, tables)
