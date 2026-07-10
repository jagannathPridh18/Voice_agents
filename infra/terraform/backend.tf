# Remote state — the bucket + lock table are created by bootstrap/terraform.
# Values here can't use variables, so fill them from the bootstrap outputs (or
# pass them at init time with `-backend-config`), e.g.:
#
#   terraform init \
#     -backend-config="bucket=dograh-tf-state-<account_id>" \
#     -backend-config="dynamodb_table=dograh-tf-locks" \
#     -backend-config="region=us-east-1" \
#     -backend-config="key=prod/terraform.tfstate"
#
# The CI workflow (.github/workflows/terraform.yml) passes these via -backend-config.
terraform {
  backend "s3" {
    key     = "prod/terraform.tfstate"
    encrypt = true
    # bucket / dynamodb_table / region supplied via -backend-config at init.
  }
}
