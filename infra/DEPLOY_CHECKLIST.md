# AWS Deploy Checklist

End-to-end steps to take this repo from "code only" to a live AWS deployment with working CI/CD. Steps marked **[admin]** require GitHub **admin** on `jagannathPridh18/Voice_agents`; steps marked **[aws-admin]** require AWS credentials with broad permissions (only the first `terraform apply` needs this — CI uses the scoped OIDC roles afterward).

> Repo: `jagannathPridh18/Voice_agents` · Project/env: `dograh` / `prod` → name prefix `dograh-prod` · Default region: `us-east-1`

---

## 0. Prerequisites

- [ ] A **domain in Route53** you control (e.g. `app.example.com`) and its **hosted zone ID**.
- [ ] **AWS CLI** authenticated with admin (for the first apply only). `aws sts get-caller-identity` should return your account.
- [ ] **Terraform ≥ 1.6**, `gh` CLI, `jq` installed.
- [ ] GitHub **admin** on the repo (to create the environment + variables). Confirm: `gh api repos/jagannathPridh18/Voice_agents --jq .permissions.admin` → `true`.

---

## 1. Fill in `infra/terraform/prod.tfvars`

- [ ] Set your real `domain_name` and `route53_zone_id` (the `github_org`/`github_repo` are already set to this fork).
- [ ] Optionally set `alarm_email` to receive CloudWatch alarm notifications.

```hcl
domain_name     = "app.example.com"     # <- your FQDN
route53_zone_id = "Z0123456789ABCDEFGHIJ" # <- hosted zone that owns it
```

---

## 2. Bootstrap the Terraform state backend  **[aws-admin]**

```bash
cd bootstrap/terraform
terraform init
terraform apply -var="project=dograh" -var="region=us-east-1"
terraform output   # note state_bucket, lock_table, region
```

---

## 3. First `terraform apply`  **[aws-admin]**

This creates everything, including the two scoped OIDC roles CI will use afterward.

```bash
cd ../../infra/terraform
terraform init \
  -backend-config="bucket=$(cd ../../bootstrap/terraform && terraform output -raw state_bucket)" \
  -backend-config="dynamodb_table=$(cd ../../bootstrap/terraform && terraform output -raw lock_table)" \
  -backend-config="region=us-east-1" \
  -backend-config="key=prod/terraform.tfstate"

terraform apply -var-file=prod.tfvars
```

- [ ] Apply completes cleanly. (ACM DNS validation can take a few minutes.)
- [ ] `terraform output` shows `app_url`, `ecr_*_repository_url`, `ecs_cluster_name`, `github_*_role_arn`, etc.

> If apply hits an `AccessDenied` on the **CI** role later, add just that action to the relevant `tf_*` policy in `modules/security/iam.tf` — don't widen to `service:*`.

---

## 4. Create the `production` GitHub Environment  **[admin]**

```bash
gh api --method PUT repos/jagannathPridh18/Voice_agents/environments/production
```

- [ ] (Optional) In the UI, add **required reviewers** so `apply` + deploys pause for approval.

---

## 5. Set the repo variables  **[admin]**

The single `CI/CD (AWS)` pipeline reads almost everything from `terraform output`, so only **5 variables** are needed (the deploy role, ECR repos, cluster, subnets, SG, and name prefix all flow from the infra job's outputs):

```bash
gh variable set AWS_REGION             --body "ap-south-1"
gh variable set AWS_TERRAFORM_ROLE_ARN --body "$(cd infra/terraform && terraform output -raw github_terraform_role_arn)"
gh variable set TF_STATE_BUCKET        --body "$(cd bootstrap/terraform && terraform output -raw state_bucket)"
gh variable set TF_LOCK_TABLE          --body "$(cd bootstrap/terraform && terraform output -raw lock_table)"
gh variable set TF_STATE_KEY           --body "prod/terraform.tfstate"

# Optional: PAT with read access to the private pipecat submodule (for the build job)
# gh secret set PIPECAT_TOKEN --body "ghp_..."
```

- [ ] `gh variable list` shows the 5 variables.

| Variable | Source |
| --- | --- |
| `AWS_REGION` | your region (`ap-south-1`) |
| `AWS_TERRAFORM_ROLE_ARN` | output `github_terraform_role_arn` |
| `TF_STATE_BUCKET` / `TF_LOCK_TABLE` | bootstrap outputs |
| `TF_STATE_KEY` | `prod/terraform.tfstate` |

---

## 6. Run the pipeline (single flow: infra → build → migrate → deploy)

```bash
gh workflow run "CI/CD (AWS)"
gh run watch "$(gh run list --workflow='CI/CD (AWS)' --limit 1 --json databaseId --jq '.[0].databaseId')"
```

One pipeline runs: `validate` → `infra` (terraform apply) → `build` (images → ECR) → `deploy` (migration `alembic upgrade head` incl. `CREATE EXTENSION vector`, then rolls all five services and waits for `services-stable`). It also runs automatically on every push to `main`.

- [ ] Pipeline is green through the `deploy` job.

---

## 7. Verify the deployment

- [ ] **Health**: `curl https://<domain>/api/v1/health` → `200` JSON with `status`.
- [ ] **UI**: open `https://<domain>` → loads; its `/api/v1/*` calls succeed.
- [ ] **WebSocket**: start a workflow run in the UI → the signaling WS to `/api/v1/ws/signaling/...` shows `101 Switching Protocols` in devtools (proves ALB WS routing to the api service).
- [ ] **TURN**: WebRTC ICE test against `turn.<domain>:3478` (or the coturn EIP) with a backend-minted credential → a `relay` candidate is gathered.
- [ ] **Migration logs**: CloudWatch `/ecs/dograh-prod/migrate` shows `CREATE EXTENSION ... vector` and `upgrade head` success.
- [ ] **CloudWatch**: log streams flowing for `api`, `ui`, `worker`, `telephony`, `orchestrator`, and `/coturn/dograh-prod`; the `dograh-prod-overview` dashboard renders.

---

## 8. Day-2 flow

- **Infra change**: edit `infra/terraform/**` → open a PR → the **Terraform** workflow posts a `plan`; merge to `main` → gated `apply` (needs `production` env approval if reviewers set).
- **App change**: cut a **GitHub Release** (or `gh workflow run "Deploy to AWS (ECS)"`) → build → migrate → roll services, zero-downtime.

---

## 9. Populating optional secrets (Sentry / PostHog / Langfuse)

Created empty in Secrets Manager as `dograh-prod/<NAME>`:

```bash
aws secretsmanager put-secret-value --secret-id dograh-prod/SENTRY_DSN --secret-string "https://..."
```

Then add the name to the api task's `secrets` in `modules/ecs/taskdefs.tf` and re-apply. LLM/telephony provider keys are **not** infra secrets — they're per-organization in the app UI (stored in Postgres).

---

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| CI `configure-aws-credentials` fails | OIDC role ARN wrong, or `github_org/repo` in `prod.tfvars` doesn't match `jagannathPridh18/Voice_agents`. Re-apply after fixing. |
| `AccessDenied` during `terraform apply` in CI | Add the missing action to the relevant `tf_*` policy in `modules/security/iam.tf`. |
| Migration task exits non-zero | Check `/ecs/dograh-prod/migrate` logs; usually DB reachability or a bad migration. The deploy stops before rolling services. |
| api targets unhealthy in ALB | Check `/ecs/dograh-prod/api`; the target group health check is `/api/v1/health` (must return 200). |
| WebSocket won't connect | Confirm the ALB `/api/v1/*` rule forwards to the api target group and the listener idle timeout is high (3600s). |
