# Dograh on AWS — Terraform + ECS Fargate + CI/CD

Infrastructure-as-code for running Dograh on AWS: **ECS Fargate** behind an **ALB (HTTPS via ACM/Route53)**, **RDS PostgreSQL (pgvector)**, **ElastiCache Redis**, **S3**, a **coturn** TURN server on EC2, and **CloudWatch** logs/alarms/dashboard. CI/CD is GitHub Actions via OIDC (no static AWS keys).

## Architecture

```
Route53 (app.example.com) ──ACM──► ALB :443
   ├─ /api/v1/*  ─► api  service (Fargate, :8000, WebSocket signaling)
   └─ default    ─► ui   service (Fargate, :3010)
                    worker service (ARQ)         ┐ private subnets
                    telephony service (ari_manager, singleton)
                    orchestrator service (campaign_orchestrator, singleton)
RDS Postgres+pgvector · ElastiCache Redis (TLS+AUTH) · S3 (voice-audio)
coturn EC2 + Elastic IP  (UDP/TCP 3478/5349 + relay 49152-49200)
CloudWatch: /ecs/dograh-prod/{api,ui,worker,telephony,orchestrator,migrate} + /coturn/*
```

One container image runs api/worker/telephony/orchestrator/migrate via ECS **command overrides** (no rebuild); the ui is a separate image.

## One-time setup

### 1. Bootstrap remote state

```bash
cd bootstrap/terraform
terraform init
terraform apply -var="project=dograh" -var="region=us-east-1"
# note the outputs: state_bucket, lock_table, region
```

### 2. Fill in `infra/terraform/prod.tfvars`

Required: `domain_name`, `route53_zone_id`, `github_org`, `github_repo`. Tune sizing as needed.

### 3. First apply (local, to create the OIDC roles + everything else)

```bash
cd infra/terraform
terraform init \
  -backend-config="bucket=<state_bucket>" \
  -backend-config="dynamodb_table=<lock_table>" \
  -backend-config="region=us-east-1" \
  -backend-config="key=prod/terraform.tfstate"
terraform apply -var-file=prod.tfvars
```

> If your AWS account already has a GitHub Actions OIDC provider, set
> `create_github_oidc_provider = false` in `prod.tfvars` first.

### 4. Wire GitHub repo variables (Settings → Secrets and variables → Actions → Variables)

The single `CI/CD (AWS)` pipeline reads most values from `terraform output`, so only **5 variables** are needed:

| Variable | Source |
| --- | --- |
| `AWS_REGION` | your region |
| `AWS_TERRAFORM_ROLE_ARN` | `github_terraform_role_arn` |
| `TF_STATE_BUCKET` | bootstrap `state_bucket` |
| `TF_LOCK_TABLE` | bootstrap `lock_table` |
| `TF_STATE_KEY` | `prod/terraform.tfstate` |

Optional: `PIPECAT_TOKEN` secret (PAT with read access to the private pipecat submodule). Also create a GitHub **Environment** named `production` (optionally with required reviewers) so the `infra` job is gated.

### 5. Run the pipeline

Run the **CI/CD (AWS)** workflow (`gh workflow run "CI/CD (AWS)"`), or just push to `main`. One flow runs: validate → infra (terraform apply) → build images → migrate (`alembic upgrade head`, incl. `CREATE EXTENSION vector`) → roll services.

## Day-2 flow

Push to `main` (touching `api/**`, `ui/**`, or `infra/terraform/**`) — the single **CI/CD (AWS)** pipeline validates, applies infra, builds images, migrates, and rolls services end-to-end. `infra` is gated behind the `production` environment for approval.

## Populating optional secrets

`SENTRY_DSN`, `POSTHOG_API_KEY`, `LANGFUSE_*` are created empty in Secrets Manager (`dograh-prod/<NAME>`). Put real values in with:

```bash
aws secretsmanager put-secret-value --secret-id dograh-prod/SENTRY_DSN --secret-string "https://..."
```

Then add them to the api task definition's `secrets` (in `modules/ecs/taskdefs.tf`) and re-apply. Provider API keys for LLM/STT/TTS/telephony are **not** infra secrets — they're configured per-organization in the app UI and stored in Postgres.

## Notes / tradeoffs

- **Telephony/ARI**: `ari_manager` connects to external Asterisk hosts configured per-org in the app; no Asterisk is provisioned here.
- **TURN over TLS (5349)** works with a real cert — the box currently serves secret-auth on 3478/5349; add a cert to `turnserver.conf` for production `turns:`.
- **Terraform role** is least-privilege (`modules/security/iam.tf`): actions are enumerated (no `service:*`), resources constrained to `${name_prefix}-*` ARNs where the service supports it (ECR/S3/Secrets/Logs/SNS/IAM/DynamoDB), and mutating statements on services that can't be ARN-scoped (EC2/ELB/ECS/RDS/ElastiCache/CloudWatch/ACM/KMS) are region-locked via `aws:RequestedRegion`. If an `apply` ever fails with `AccessDenied` for a specific action, add just that action to the relevant `tf_*` policy — don't widen back to `service:*`.
- ECS task definitions are Terraform-managed but services `ignore_changes` on `task_definition`/`desired_count` so CI deploys and autoscaling don't fight Terraform.
