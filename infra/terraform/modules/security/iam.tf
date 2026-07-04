# ---------------------------------------------------------------------------
# GitHub Actions OIDC provider + roles (no static AWS keys in CI)
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_github_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  repo_sub          = "repo:${var.github_org}/${var.github_repo}:*"
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.repo_sub]
    }
  }
}

# --- Terraform role (broad infra perms, used by terraform.yml) ---------------
resource "aws_iam_role" "github_terraform" {
  name               = "${var.name_prefix}-gha-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# Least-privilege Terraform role. Rather than service:* the actions are
# enumerated, resources are constrained to this stack's "${name_prefix}-*"
# ARNs wherever the service supports resource-level permissions, and every
# mutating statement on services that can't be ARN-scoped (EC2/ELB/ECS/RDS/…)
# is locked to var.region via aws:RequestedRegion. Read (Describe/List/Get) is
# left on "*" — it's non-mutating.
#
# NOTE: if a `terraform apply` ever fails with AccessDenied for a specific
# action, add just that action to the relevant policy below — do not widen to
# service:*.
locals {
  tf_region_lock = { StringEquals = { "aws:RequestedRegion" = var.region } }

  iam_role_glob             = "arn:aws:iam::${var.account_id}:role/${var.name_prefix}-*"
  iam_policy_glob           = "arn:aws:iam::${var.account_id}:policy/${var.name_prefix}-*"
  iam_instance_profile_glob = "arn:aws:iam::${var.account_id}:instance-profile/${var.name_prefix}-*"
  iam_slr_glob              = "arn:aws:iam::${var.account_id}:role/aws-service-role/*"
  iam_oidc_arn              = "arn:aws:iam::${var.account_id}:oidc-provider/token.actions.githubusercontent.com"

  tf_state_bucket_arn = "arn:aws:s3:::${var.project}-tf-state-${var.account_id}"
  tf_lock_table_arn   = "arn:aws:dynamodb:${var.region}:${var.account_id}:table/${var.project}-tf-locks"
  ecr_repo_glob       = "arn:aws:ecr:${var.region}:${var.account_id}:repository/${var.name_prefix}-*"
  sns_topic_glob      = "arn:aws:sns:${var.region}:${var.account_id}:${var.name_prefix}-*"
  logs_globs = [
    "arn:aws:logs:${var.region}:${var.account_id}:log-group:/ecs/${var.name_prefix}/*",
    "arn:aws:logs:${var.region}:${var.account_id}:log-group:/coturn/${var.name_prefix}*",
  ]
}

# --- Network: EC2 + ELB -----------------------------------------------------
resource "aws_iam_policy" "tf_network" {
  name = "${var.name_prefix}-tf-network"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Ec2ElbRead"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "ec2:GetSecurityGroupsForVpc", "elasticloadbalancing:Describe*"]
        Resource = "*"
      },
      {
        Sid       = "Ec2Write"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = "*"
        Action = [
          "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
          "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
          "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
          "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
          "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:AssociateRouteTable",
          "ec2:DisassociateRouteTable", "ec2:ReplaceRouteTableAssociation",
          "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
          "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:AssociateAddress", "ec2:DisassociateAddress",
          "ec2:CreateNatGateway", "ec2:DeleteNatGateway",
          "ec2:CreateVpcEndpoint", "ec2:DeleteVpcEndpoints", "ec2:ModifyVpcEndpoint",
          "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
          "ec2:ModifySecurityGroupRules",
          "ec2:UpdateSecurityGroupRuleDescriptionsIngress", "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
          "ec2:RunInstances", "ec2:TerminateInstances", "ec2:StartInstances", "ec2:StopInstances",
          "ec2:ModifyInstanceAttribute", "ec2:ModifyInstanceMetadataOptions",
          "ec2:CreateTags", "ec2:DeleteTags",
        ]
      },
      {
        Sid       = "ElbWrite"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = "*"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetSecurityGroups", "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:CreateListener", "elasticloadbalancing:DeleteListener", "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule", "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags",
        ]
      },
    ]
  })
}

# --- Containers: ECS + ECR + Cloud Map + App Autoscaling --------------------
resource "aws_iam_policy" "tf_containers" {
  name = "${var.name_prefix}-tf-containers"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ContainersRead"
        Effect = "Allow"
        Action = [
          "ecs:Describe*", "ecs:List*",
          "ecr:Describe*", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy", "ecr:ListTagsForResource",
          "servicediscovery:Get*", "servicediscovery:List*",
          "application-autoscaling:Describe*", "application-autoscaling:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid       = "EcsWrite"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = "*"
        Action = [
          "ecs:CreateCluster", "ecs:DeleteCluster", "ecs:PutClusterCapacityProviders",
          "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition",
          "ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService",
          "ecs:TagResource", "ecs:UntagResource",
          "servicediscovery:CreatePrivateDnsNamespace", "servicediscovery:DeleteNamespace",
          "servicediscovery:CreateService", "servicediscovery:DeleteService",
          "servicediscovery:UpdateService", "servicediscovery:TagResource", "servicediscovery:UntagResource",
          "application-autoscaling:RegisterScalableTarget", "application-autoscaling:DeregisterScalableTarget",
          "application-autoscaling:PutScalingPolicy", "application-autoscaling:DeleteScalingPolicy",
          "application-autoscaling:TagResource",
        ]
      },
      {
        Sid       = "EcrWrite"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = local.ecr_repo_glob
        Action = [
          "ecr:CreateRepository", "ecr:DeleteRepository",
          "ecr:PutLifecyclePolicy", "ecr:DeleteLifecyclePolicy",
          "ecr:PutImageScanningConfiguration", "ecr:SetRepositoryPolicy", "ecr:DeleteRepositoryPolicy",
          "ecr:TagResource", "ecr:UntagResource",
        ]
      },
    ]
  })
}

# --- Data: RDS + ElastiCache + S3 + DynamoDB + Secrets + KMS ----------------
resource "aws_iam_policy" "tf_data" {
  name = "${var.name_prefix}-tf-data"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DataRead"
        Effect = "Allow"
        Action = [
          "rds:Describe*", "rds:ListTagsForResource",
          "elasticache:Describe*", "elasticache:ListTagsForResource",
        ]
        Resource = "*"
      },
      {
        Sid       = "RdsElasticacheWrite"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = "*"
        Action = [
          "rds:CreateDBInstance", "rds:DeleteDBInstance", "rds:ModifyDBInstance",
          "rds:CreateDBSubnetGroup", "rds:DeleteDBSubnetGroup", "rds:ModifyDBSubnetGroup",
          "rds:CreateDBParameterGroup", "rds:DeleteDBParameterGroup", "rds:ModifyDBParameterGroup",
          "rds:CreateDBSnapshot", "rds:AddTagsToResource", "rds:RemoveTagsFromResource",
          "elasticache:CreateReplicationGroup", "elasticache:DeleteReplicationGroup", "elasticache:ModifyReplicationGroup",
          "elasticache:CreateCacheSubnetGroup", "elasticache:DeleteCacheSubnetGroup", "elasticache:ModifyCacheSubnetGroup",
          "elasticache:AddTagsToResource", "elasticache:RemoveTagsFromResource",
        ]
      },
      {
        Sid    = "S3StackBuckets"
        Effect = "Allow"
        Action = ["s3:*"]
        Resource = [
          var.s3_bucket_arn, "${var.s3_bucket_arn}/*",
          local.tf_state_bucket_arn, "${local.tf_state_bucket_arn}/*",
        ]
      },
      {
        Sid      = "DynamoStateLock"
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
        Resource = local.tf_lock_table_arn
      },
      {
        Sid    = "Secrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecret",
          "secretsmanager:TagResource", "secretsmanager:UntagResource",
          "secretsmanager:ListSecretVersionIds", "secretsmanager:RestoreSecret",
          "secretsmanager:GetResourcePolicy",
        ]
        Resource = var.secret_arn_prefix
      },
      {
        Sid       = "KmsForManagedKeys"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = "*"
        Action = [
          "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey",
          "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:CreateGrant", "kms:RetireGrant",
        ]
      },
      {
        Sid       = "Efs"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = "*"
        Action    = ["elasticfilesystem:*"]
      },
    ]
  })
}

# --- Ops: Logs + CloudWatch + SNS + ACM + Route53 ---------------------------
resource "aws_iam_policy" "tf_ops" {
  name = "${var.name_prefix}-tf-ops"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OpsRead"
        Effect = "Allow"
        Action = [
          "logs:Describe*", "logs:ListTagsForResource",
          "cloudwatch:DescribeAlarms", "cloudwatch:GetDashboard", "cloudwatch:ListDashboards", "cloudwatch:ListTagsForResource",
          "sns:ListTopics", "sns:ListSubscriptionsByTopic", "sns:GetSubscriptionAttributes",
          "acm:DescribeCertificate", "acm:ListCertificates", "acm:ListTagsForCertificate", "acm:GetCertificate",
        ]
        Resource = "*"
      },
      {
        Sid      = "LogsWrite"
        Effect   = "Allow"
        Resource = local.logs_globs
        Action = [
          "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
          "logs:PutMetricFilter", "logs:DeleteMetricFilter", "logs:TagResource", "logs:UntagResource",
          "logs:AssociateKmsKey", "logs:DisassociateKmsKey",
        ]
      },
      {
        Sid       = "CloudWatchWrite"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = "*"
        Action = [
          "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms",
          "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards",
          "cloudwatch:TagResource", "cloudwatch:UntagResource",
        ]
      },
      {
        Sid      = "SnsWrite"
        Effect   = "Allow"
        Resource = local.sns_topic_glob
        Action = [
          "sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes",
          "sns:Subscribe", "sns:Unsubscribe", "sns:TagResource", "sns:UntagResource", "sns:ListTagsForResource",
        ]
      },
      {
        Sid       = "AcmWrite"
        Effect    = "Allow"
        Condition = local.tf_region_lock
        Resource  = "*"
        Action    = ["acm:RequestCertificate", "acm:DeleteCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate"]
      },
      {
        # Route53 is global (no region-level ARNs) and Cloud Map creates a
        # private hosted zone under the hood, so these stay on "*".
        Sid    = "Route53"
        Effect = "Allow"
        Action = [
          "route53:CreateHostedZone", "route53:DeleteHostedZone", "route53:GetHostedZone", "route53:ListHostedZones",
          "route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:GetChange",
          "route53:ChangeTagsForResource", "route53:ListTagsForResource",
          "route53:AssociateVPCWithHostedZone", "route53:DisassociateVPCFromHostedZone",
        ]
        Resource = "*"
      },
    ]
  })
}

# --- IAM (scoped to this stack's roles/policies/profiles + the OIDC provider)
resource "aws_iam_policy" "tf_iam" {
  name = "${var.name_prefix}-tf-iam"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StsIdentity"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
      {
        Sid    = "ManageStackRolesPoliciesProfiles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
          "iam:UpdateAssumeRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListRoleTags",
          "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListInstanceProfilesForRole",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:GetPolicyVersion",
          "iam:TagPolicy", "iam:UntagPolicy",
        ]
        Resource = [local.iam_role_glob, local.iam_policy_glob, local.iam_instance_profile_glob]
      },
      {
        Sid    = "OidcProvider"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider", "iam:GetOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
          "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider",
        ]
        Resource = local.iam_oidc_arn
      },
      {
        Sid       = "PassStackRolesToServices"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = local.iam_role_glob
        Condition = { StringEquals = { "iam:PassedToService" = ["ecs-tasks.amazonaws.com", "ec2.amazonaws.com"] } }
      },
      {
        Sid       = "ServiceLinkedRoles"
        Effect    = "Allow"
        Action    = ["iam:CreateServiceLinkedRole"]
        Resource  = local.iam_slr_glob
        Condition = { StringEquals = { "iam:AWSServiceName" = ["ecs.amazonaws.com", "elasticache.amazonaws.com", "rds.amazonaws.com", "ecs.application-autoscaling.amazonaws.com", "elasticloadbalancing.amazonaws.com"] } }
      },
      {
        Sid      = "ReadOidcListForDataSource"
        Effect   = "Allow"
        Action   = ["iam:ListOpenIDConnectProviders"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "tf" {
  for_each = {
    network    = aws_iam_policy.tf_network.arn
    containers = aws_iam_policy.tf_containers.arn
    data       = aws_iam_policy.tf_data.arn
    ops        = aws_iam_policy.tf_ops.arn
    iam        = aws_iam_policy.tf_iam.arn
  }
  role       = aws_iam_role.github_terraform.name
  policy_arn = each.value
}

# --- Deploy role (scoped: push images + roll ECS, used by deploy-aws.yml) ----
resource "aws_iam_role" "github_deploy" {
  name               = "${var.name_prefix}-gha-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage", "ecr:PutImage", "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
    ]
    resources = ["arn:aws:ecr:${var.region}:${var.account_id}:repository/${var.name_prefix}-*"]
  }

  statement {
    sid    = "EcsDeploy"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices", "ecs:UpdateService",
      "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition",
      "ecs:DescribeTaskDefinition", "ecs:ListTaskDefinitions",
      "ecs:RunTask", "ecs:DescribeTasks", "ecs:ListTasks",
      "ecs:TagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PassEcsRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${var.account_id}:role/${var.name_prefix}-*"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "MigrationLogs"
    effect    = "Allow"
    actions   = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:DescribeLogStreams"]
    resources = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:/ecs/${var.name_prefix}/*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

# ---------------------------------------------------------------------------
# ECS roles
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: pull images + write logs + read the container secrets.
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadSecrets"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.secret_arn_prefix]
  }
  statement {
    sid       = "DecryptSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# App task role: S3 access for api/worker/telephony (boto3 default cred chain).
resource "aws_iam_role" "app_task" {
  name               = "${var.name_prefix}-ecs-app-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "app_task_s3" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.s3_bucket_arn]
  }
  statement {
    sid       = "Objects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.s3_bucket_arn}/*"]
  }
}

resource "aws_iam_role_policy" "app_task_s3" {
  name   = "s3-access"
  role   = aws_iam_role.app_task.id
  policy = data.aws_iam_policy_document.app_task_s3.json
}

# UI task role: no AWS API access needed.
resource "aws_iam_role" "ui_task" {
  name               = "${var.name_prefix}-ecs-ui-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}
