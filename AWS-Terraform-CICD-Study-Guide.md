# AWS Terraform + GitHub Actions OIDC Study Guide

This document captures the practical knowledge built while configuring a Terraform-managed static website on Amazon S3 using GitHub Actions with AWS OIDC authentication and remote Terraform state.

It is designed to help with:
- AWS Certified Solutions Architect learning
- AWS Certified Developer learning
- Terraform and AWS automation practice
- GitHub Actions CI/CD fundamentals
- Real-world debugging of IAM, S3, and Terraform issues

It also contains notes that are useful for future LLM-assisted study and project troubleshooting.

---

## 1. Project Goal

Build and deploy a static website hosted on Amazon S3 using:
- Terraform for infrastructure as code
- GitHub Actions for CI/CD automation
- AWS IAM OIDC for secure, passwordless authentication
- S3 remote state backend for multi-run consistency

The final architecture is:

GitHub repository
  -> GitHub Actions workflow
  -> OIDC token exchanged for AWS temporary credentials
  -> IAM role assumed by GitHub Actions
  -> Terraform runs against AWS
  -> S3 website bucket created/updated
  -> Terraform state stored in dedicated S3 backend bucket

---

## 2. Why This Project Matters

This project combines three core areas that appear heavily in AWS and DevOps work:

1. IAM and authentication security
   - OIDC trust policies
   - Role assumptions without long-lived AWS access keys
   - Principle of least privilege

2. Infrastructure as Code
   - Declarative configuration
   - Repeatable deployments
   - Remote state and locking

3. CI/CD automation
   - GitHub Actions triggers on push/PR
   - Secure, automated AWS deployments
   - State awareness and safe infra updates

This is exactly the sort of real-world knowledge that scales to both exam study and production work.

---

## 3. Core Architecture

### 3.1 AWS Components Used

- Amazon S3 bucket for static website hosting
- IAM OIDC identity provider for GitHub Actions
- IAM role to allow GitHub Actions to assume AWS permissions
- Terraform remote backend in S3
- DynamoDB table for locking (or lockfile alternative depending on Terraform version)

### 3.2 GitHub Components Used

- GitHub repository
- GitHub Actions workflow
- `aws-actions/configure-aws-credentials@v4`
- `hashicorp/setup-terraform@v3`
- `actions/checkout@v4`

### 3.3 Core Flow

1. Developer pushes code to main or opens a PR
2. GitHub Actions starts the workflow
3. OIDC token is generated for the repo and branch
4. AWS validates the trust policy
5. Role is assumed via `sts:AssumeRoleWithWebIdentity`
6. Terraform initializes and runs against the remote backend
7. State is read/written from S3
8. Infrastructure is created/updated in AWS

---

## 4. Critical Concepts

### 4.1 OIDC (OpenID Connect)

OIDC allows GitHub Actions to authenticate to AWS without storing AWS credentials in GitHub secrets.

This is important because:
- no long-lived AWS secret keys are stored in GitHub
- roles are temporary and short-lived
- permissions remain tightly scoped

### 4.2 IAM Trust Policy

The trust policy lives on the IAM role and defines who can assume it.

A typical trust policy pattern looks like this:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:adeomomo@*/S3-Static-website@*:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

This is the key learning point: the `sub` claim in GitHub's OIDC token includes numeric ids in the modern format, for example:

```text
repo:adeomomo@15641347/S3-Static-website@1363524398:ref:refs/heads/main
```

This is why a strict old-style pattern like:

```text
repo:adeomomo/S3-Static-website:ref:refs/heads/main
```

failed even though it looked logically correct.

### 4.3 IAM Role and Permissions

The role used by GitHub Action must have permissions to perform the Terraform operations needed.

For example, it needs permission to create/update S3 buckets, bucket policies, bucket ACL settings, and other AWS resources.

This is a perfect example of least privilege in practice:
- the GitHub runner is not given permanent AWS keys
- the role is scoped to the exact repo/branch and required actions

### 4.4 Terraform State

Terraform state is a snapshot of your infrastructure. It is required for Terraform to know what exists in AWS.

Without state, Terraform thinks everything should be created from scratch every run.

This is why we saw repeated errors like:
- `BucketAlreadyOwnedByYou`
- `Resource already managed by Terraform`
- Terraform trying to recreate an existing bucket

### 4.5 Remote State Backend

The state backend must be stored in a durable, shared location. The correct approach is to use a dedicated S3 bucket for Terraform state, such as:

```text
adeomomo-terraform-state
```

Then the Terraform backend config should look like:

```hcl
terraform {
  backend "s3" {
    bucket         = "adeomomo-terraform-state"
    key            = "s3-website/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

This ensures:
- remote state is shared across runs
- multi-user safety
- state lock protection

### 4.6 DynamoDB Locking

Terraform uses state locking to prevent simultaneous writes.

The DynamoDB table provides a lock for `terraform apply` operations. This avoids a race condition where two runs try to modify the same AWS resources at the same time.

---

## 5. Practical Problem Sequence We Solved

Here is the real issue timeline and the learning value behind each problem.

### 5.1 OIDC Role Assumption Failed

Error:

```text
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

Cause:
- trust policy mismatch
- GitHub OIDC subject format changed
- old trust policy pattern used the wrong `sub` claim

Fix:
- update trust policy to the correct modern format using wildcard matching and the repo/user/repo-id pattern

Key lesson:
- do not assume the old GitHub OIDC subject format is still valid
- CloudTrail is your best friend when debugging AWS auth issues

### 5.2 InvalidClientTokenId

Cause:
- AWS CLI on the local machine was using the wrong profile or bad credentials
- the CLI was not authenticated correctly

Fix:
- reconfigure AWS CLI using the right profile
- verify with `aws sts get-caller-identity`

Key lesson:
- AWS CLI auth must be correct before interacting with IAM or OIDC setup

### 5.3 Terraform Profile Hardcoded to Old CLI Profile

Problem:
- `providers.tf` had a stale profile like `aws-admin-cert`
- Terraform attempted to use a missing AWS profile instead of the environment from GitHub Actions

Fix:
- remove the hardcoded profile
- let AWS credentials from OIDC be used automatically

Key lesson:
- when using GitHub OIDC, do not force a local profile in CI

### 5.4 Bucket Already Exists

Cause:
- Terraform had no remote state in S3
- the bucket already existed in AWS
- Terraform thought it was a new bucket

Fix:
- configure backend S3 state storage
- initialize Terraform with backend configuration
- import the existing bucket into state if required

Key lesson:
- remote state is mandatory for repeatable Terraform work

### 5.5 Resource Already Managed by Terraform

Cause:
- the bucket resource already existed in state
- a second import was attempted

Fix:
- do not re-import the resource
- verify state and run `terraform plan`

Key lesson:
- state is the truth source, not the AWS console alone

---

## 6. Terraform Commands You Should Know

### 6.1 AWS CLI Authentication Checks

```bash
aws sts get-caller-identity
aws sts get-caller-identity --profile admin
aws sts get-caller-identity --profile cicd
```

### 6.2 OIDC Provider Setup

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --profile admin
```

### 6.3 Trust Policy Update

```bash
aws iam update-assume-role-policy \
  --role-name GitHubActionsTerraformRole \
  --policy-document file://trust-policy-fixed.json \
  --profile admin
```

### 6.4 Backend Setup

```bash
aws s3api create-bucket \
  --bucket adeomomo-terraform-state \
  --region ap-southeast-2 \
  --create-bucket-configuration LocationConstraint=ap-southeast-2 \
  --profile admin
```

```bash
aws s3api put-bucket-versioning \
  --bucket adeomomo-terraform-state \
  --versioning-configuration Status=Enabled \
  --profile admin
```

```bash
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-southeast-2 \
  --profile admin
```

### 6.5 Terraform Initialization

```bash
terraform init
terraform init -reconfigure
```

### 6.6 Terraform Import

```bash
terraform import aws_s3_bucket.website_bucket adeomomo-aws-project-website
```

### 6.7 State Inspection

```bash
terraform state list
terraform state show aws_s3_bucket.website_bucket
terraform state pull
```

### 6.8 Plan and apply

```bash
terraform plan
terraform apply
terraform apply -auto-approve
```

---

## 7. Correct Terraform Backend Example

This is the final pattern used for secure, repeatable state management.

```hcl
terraform {
  backend "s3" {
    bucket         = "adeomomo-terraform-state"
    key            = "s3-website/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

If using newer Terraform with `use_lockfile`:

```hcl
terraform {
  backend "s3" {
    bucket       = "adeomomo-terraform-state"
    key          = "s3-website/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

---

## 8. Example Terraform Provider File

```hcl
terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
}
```

This is the correct pattern when using GitHub Actions OIDC. Do not hardcode a local AWS profile in CI.

---

## 9. Example S3 Website Terraform File

```hcl
resource "aws_s3_bucket" "website_bucket" {
  bucket        = "adeomomo-aws-project-website"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "website_block" {
  bucket                  = aws_s3_bucket.website_bucket.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website_policy" {
  depends_on = [aws_s3_bucket_public_access_block.website_block]
  bucket     = aws_s3_bucket.website_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.website_bucket.arn}/*"
      }
    ]
  })
}

resource "aws_s3_bucket_website_configuration" "website_config" {
  bucket = aws_s3_bucket.website_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

output "website_endpoint" {
  value       = aws_s3_bucket_website_configuration.website_config.website_endpoint
  description = "The public endpoint of the static website."
}
```

---

## 10. GitHub Actions Workflow Pattern

```yaml
name: 'Terraform CI/CD'

on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["main"]

permissions:
  id-token: write
  contents: read

jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Authenticate to AWS
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ap-southeast-2

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.8.0

      - name: Terraform Init
        run: terraform init

      - name: Terraform Validate
        run: terraform validate

      - name: Terraform Plan
        run: terraform plan -no-color

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply -auto-approve
```

---

## 11. Common AWS Errors and What They Mean

### 11.1 `InvalidClientTokenId`

Meaning:
- the AWS CLI is using invalid credentials or wrong profile

Fix:
- reconfigure AWS CLI
- verify with `aws sts get-caller-identity`

### 11.2 `Not authorized to perform sts:AssumeRoleWithWebIdentity`

Meaning:
- trust policy does not match the GitHub token claims
- GitHub OIDC sub claim not matched

Fix:
- align trust policy with the actual subject claim format
- use `StringLike` and wildcard patterns if needed

### 11.3 `BucketAlreadyOwnedByYou`

Meaning:
- the S3 bucket already exists in the same AWS account
- Terraform is trying to create it because state is missing or stale

Fix:
- use remote state
- import the bucket if it is already created

### 11.4 `Resource already managed by Terraform`

Meaning:
- the object already exists in Terraform state

Fix:
- do not import it again
- run `terraform plan`

### 11.5 `aws-admin-cert profile not found`

Meaning:
- Terraform is trying to use a deleted or stale AWS profile

Fix:
- remove hardcoded profile values from provider config
- use OIDC credentials in CI

---

## 12. Study Notes for AWS Certification

### 12.1 IAM Concepts to Know

- IAM users vs IAM roles
- policies and permissions boundaries
- least privilege
- federation and OIDC
- STS AssumeRole and AssumeRoleWithWebIdentity
- role trust policies
- temporary credentials

### 12.2 S3 Concepts to Know

- static website hosting
- bucket policies vs ACLs
- public access block
- website endpoints
- object permissions
- bucket naming uniqueness and global namespace

### 12.3 Terraform Concepts to Know

- infrastructure as code
- declarative syntax
- providers and resources
- state files and remote backends
- Terraform plan/apply lifecycle
- locking and concurrency safety
- import command for existing resources

### 12.4 DevOps / CI-CD Concepts to Know

- GitHub Actions triggers and permissions
- OIDC-based cloud access
- secrets vs identity-based auth
- pipelines as code
- infrastructure drift detection
- remote state and versioning

---

## 13. Study Plan: How to Learn This Well

### Phase 1: Fundamentals

- Learn IAM basics: users, groups, roles, policies, trust policies
- Understand OIDC vs IAM user access keys
- Learn how AWS uses STS tokens
- Understand why secret rotation is important

### Phase 2: Terraform Basics

- Learn Terraform lifecycle: init, plan, apply, destroy
- Understand resource blocks and providers
- Learn how Terraform tracks state
- Practice editing resources and seeing drift

### Phase 3: Remote State and Locking

- Create a backend S3 bucket
- Store state remotely
- Add DynamoDB locking
- Learn how state prevents duplicate creation

### Phase 4: GitHub Actions and OIDC

- Set up a workflow after understanding AWS IAM permissions
- Test OIDC trust policy with staged changes
- Validate by reading CloudTrail logs

### Phase 5: Troubleshooting

- Practice reading AWS error messages carefully
- Learn to distinguish between auth, state, and configuration issues
- Use `terraform state list`, `terraform plan`, and `aws cloudtrail lookup-events`

---

## 14. The Most Important Lessons from This Project

1. IAM trust policy details matter more than they look.
2. GitHub OIDC subject format changed and may not match older examples.
3. Remote state is mandatory for repeatable Terraform automation.
4. Terraform and AWS can both be correct independently while still failing together because state is missing.
5. `BucketAlreadyOwnedByYou` is a state problem, not necessarily a permission problem.
6. Always verify the repo/branch in GitHub Actions matches the trust policy subject.
7. Use CloudTrail to inspect AWS API calls when authentication or role assumption fails.
8. One bad AWS profile or stale config in Terraform can derail CI even when the cloud path is otherwise valid.

---

## 15. Practical Checklists

### Before pushing to GitHub

- AWS trust policy is correct for repo and branch
- GitHub Actions role ARN is valid
- Terraform backend `.tf` file exists and is committed
- State bucket exists and is accessible
- DynamoDB lock table exists if using locking
- `providers.tf` does not hardcode a stale AWS local profile
- `terraform init` works locally
- `terraform validate` passes

### Before applying in AWS

- `terraform plan` is reviewed
- state is remote and shared
- no conflicting resources exist in another state file
- bucket names are unique and correct

### When something fails

- check `aws sts get-caller-identity`
- check AWS CloudTrail for STS events
- check `terraform state list`
- check `terraform plan`
- check whether state is in the backend bucket

---

## 16. Prompt-Friendly Summary for Future LLM Work

Use this as a quick summary for future study sessions:

This project demonstrates secure Terraform automation on AWS using GitHub OIDC. The main problems encountered were:
- IAM trust policy mismatch for GitHub Actions OIDC subject claims
- stale local AWS profiles in Terraform config
- missing remote Terraform state backend
- attempting to create an already-existing S3 bucket due to missing state
- import confusion when terraform state already existed

The final working pattern:
- GitHub Actions authenticates to AWS with OIDC
- IAM role is assumed via `sts:AssumeRoleWithWebIdentity`
- Terraform uses a remote S3 backend for state
- Terraform state is locked in DynamoDB or via lockfile
- existing AWS resources are managed via state rather than recreated

---

## 17. Final Advice

If you want to deepen your skill set, continue with these next steps:

1. Create another Terraform project using EC2, VPC, or RDS
2. Add separate dev/prod workspaces
3. Practice remote state and state lock behavior
4. Use GitHub Actions with branch-based deployments
5. Read CloudTrail logs for every auth failure
6. Study the AWS shared responsibility model and least-privilege IAM design
7. Practice using the AWS CLI and Terraform together until the mental model is automatic

---

## 18. Quick Reference: One-Page Mental Model

- GitHub Actions = CI/CD runner
- OIDC = passwordless AWS auth
- IAM Role = the AWS permission boundary for GitHub Actions
- Trust Policy = who can assume that role
- Terraform State = the real infrastructure inventory
- S3 Backend = remote, durable state store
- DynamoDB Lock = prevents parallel writes
- S3 Bucket = actual website resource
- BucketAlreadyOwnedByYou = state problem
- Not authorized to assume role = trust policy problem

---

## 19. Suggested Next Projects

To continue developing practical knowledge, the next best exercises are:

- Deploy a static site with CloudFront and S3
- Add Route53 DNS records
- Add a simple Lambda + API Gateway project
- Move from static hosting to Docker-based app deployment
- Add Terraform workspaces for dev/test/prod
- Add secure secret handling and environment-based variables

---

## 20. Closing Note

This project is a strong example of the intersection between AWS, Terraform, and CI/CD. It teaches not just configuration syntax, but also the operational mindset required for real systems:

- confirm authentication flows
- verify state
- read AWS logs carefully
- secure trust boundaries
- design for repeatability
- prefer durable remote state over local assumptions

That is the difference between learning commands and learning to build reliable cloud systems.

---

## 21. Beginner-Friendly Cheat Sheet

```bash
# Check AWS identity
aws sts get-caller-identity

# Check Terraform state
terraform state list
terraform state show aws_s3_bucket.website_bucket

# Initialize Terraform backend
terraform init -reconfigure

# Import existing bucket
terraform import aws_s3_bucket.website_bucket adeomomo-aws-project-website

# Check plan
terraform plan

# Apply changes
terraform apply -auto-approve

# Check CloudTrail auth failures
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 10
```

---

This guide is intentionally practical, because real cloud learning is not just syntax — it is troubleshooting, reasoning, and understanding state and identity.

Use this file as a reference while studying for AWS certifications and while building your Terraform + AWS automation skills.
