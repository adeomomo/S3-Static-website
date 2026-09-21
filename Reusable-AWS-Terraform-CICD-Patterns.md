# Reusing AWS Users, Roles, and CI/CD Patterns in Future Projects

This guide explains how to apply the lessons learned from the Terraform + S3 + GitHub Actions + OIDC project to future AWS and DevOps projects.

It also explains which parts of the project are reusable and which parts must be created per project.

---

## 1. Recommended AWS identity model

### 1.1 Human access

Use human IAM access only for administrative tasks, such as:
- creating the GitHub OIDC provider
- creating IAM roles and trust policies
- admin-level AWS maintenance
- initial project setup
- troubleshooting account-level permissions

For a production account, prefer IAM Identity Center / SSO or federated access instead of long-lived IAM user access keys.

A typical local setup might look like:

```ini
[profile admin]
region = ap-southeast-2

[profile developer]
region = ap-southeast-2
```

Use the admin profile only when needed:

```bash
aws sts get-caller-identity --profile admin
```

Use a lower-permission developer profile or federated login for day-to-day non-admin work.

### 1.2 Automation access

GitHub Actions should use an AWS IAM role through OIDC instead of static AWS access keys.

The pattern is:

```text
GitHub Actions
  -> OIDC token
  -> AWS OIDC provider
  -> IAM role assumed by the workflow
  -> temporary AWS credentials
```

This is much safer than storing long-lived AWS keys in GitHub secrets.

---

## 2. Account-level vs project-level resources

### 2.1 Reusable at the AWS account level

These are usually created once and reused across multiple projects:

- GitHub OIDC provider
  - `arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com`
- IAM admin identity for account setup
- Security and account-wide tagging standards
- Shared governance patterns

### 2.2 Project-specific resources

These must usually be created separately for each project:

- GitHub Actions role for that repo
- IAM role trust policy
- Terraform backend state path
- State lock table configuration
- Terraform modules
- AWS application resources
- GitHub environments and branch protections

Example:

```text
Project A:
  role: GitHubActionsTerraformRole-website
  state key: website/dev/terraform.tfstate

Project B:
  role: GitHubActionsTerraformRole-api
  state key: api/dev/terraform.tfstate
```

This prevents one repository from being able to manage another repository's AWS resources.

---

## 3. GitHub OIDC role design for future projects

Each project should have its own IAM role, scoped to the repository and branch/environment.

Example trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::895492487659:oidc-provider/token.actions.githubusercontent.com"
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

For future projects, create a new role with a matching subject filter for that repo.

Avoid broad rules like:

```text
repo:adeomomo/*
```

unless you intentionally want all repos in the org to assume that role.

---

## 4. Separate roles by environment

A strong practice is to create separate roles such as:

```text
GitHubActionsTerraformRole-website-dev
GitHubActionsTerraformRole-website-prod
```

This is especially useful when:
- dev and prod workloads should be isolated
- different approval gates are required
- you want more precise auditing

You can also use GitHub Environments and approval rules.

Example:

```yaml
jobs:
  deploy:
    environment: production
```

This gives you environment-level protection and deployment review workflows.

---

## 5. Reusable CI/CD components

These parts of the project are highly reusable.

### 5.1 Checkout stage

```yaml
- name: Checkout code
  uses: actions/checkout@v4
```

### 5.2 OIDC permissions

```yaml
permissions:
  id-token: write
  contents: read
```

### 5.3 AWS authentication step

```yaml
- name: Authenticate to AWS
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
    aws-region: ap-southeast-2
```

This pattern works for many projects. The only thing that usually changes is the IAM role ARN and region.

### 5.4 Terraform setup

```yaml
- name: Setup Terraform
  uses: hashicorp/setup-terraform@v3
  with:
    terraform_version: 1.8.0
```

### 5.5 Standard Terraform stages

```yaml
- name: Terraform Init
  run: terraform init

- name: Terraform Format Check
  run: terraform fmt -check -recursive

- name: Terraform Validate
  run: terraform validate

- name: Terraform Plan
  run: terraform plan -no-color
```

These are reusable across nearly all Terraform repos.

---

## 6. Reusable Terraform backend pattern

The state backend must be kept separate from the actual deployed resources.

For example:

```hcl
terraform {
  backend "s3" {
    bucket         = "adeomomo-terraform-state"
    key            = "website/dev/terraform.tfstate"
    region         = "ap-southeast-2"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

The state bucket is not the resource bucket. In this project:

- `adeomomo-terraform-state` = Terraform state
- `adeomomo-aws-project-website` = actual website resource bucket

This distinction is important and reusable for every project.

### Design rule

The state key should be unique per project and per environment.

Examples:

```text
website/dev/terraform.tfstate
website/prod/terraform.tfstate
api/dev/terraform.tfstate
api/prod/terraform.tfstate
```

Do not reuse the same key across unrelated stacks.

---

## 7. Reusable Terraform provider pattern

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

This is reusable across nearly all AWS projects.

Important:
- in GitHub Actions, do not hardcode a local AWS profile
- let the environment provide AWS credentials through OIDC

---

## 8. Reusable AWS command patterns

A few commands should become part of your standard workflow for future Terraform projects.

### 8.1 Verify current AWS identity

```bash
aws sts get-caller-identity
```

### 8.2 Check track of auth failures

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 10
```

### 8.3 List Terraform state

```bash
terraform state list
terraform state show aws_s3_bucket.website_bucket
```

### 8.4 Reinitialize with backend

```bash
terraform init -reconfigure
```

### 8.5 Import an existing resource

```bash
terraform import aws_s3_bucket.website_bucket adeomomo-aws-project-website
```

### 8.6 Plan and apply

```bash
terraform plan
terraform apply -auto-approve
```

---

## 9. Reusable project structure

As your projects grow, build a standard repo structure like this:

```text
project-name/
├── .github/
│   └── workflows/
│       └── terraform.yml
├── backend.tf
├── providers.tf
├── main.tf
├── variables.tf
├── outputs.tf
├── README.md
├── .gitignore
└── .terraform.lock.hcl
```

This is the pattern to reuse across future projects.

---

## 10. Suggested future guides to create

These are the best additional study guides to create from this exercise.

### 10.1 AWS IAM, Roles, and Trust Policies Guide

This should include:
- IAM users vs roles
- trust policies
- `sts:AssumeRole`
- `sts:AssumeRoleWithWebIdentity`
- OIDC from GitHub Actions to AWS
- principals, conditions, and `sub` claims
- least privilege examples

### 10.2 Terraform State Management Guide

This should include:
- what Terraform state is
- why remote state is required
- S3 backend configuration
- DynamoDB locking
- `terraform init`, `plan`, `apply`, `import`, `state show`, `state list`
- state drift and state recovery practices

### 10.3 GitHub Actions for AWS Deployment Guide

This should include:
- `actions/checkout`
- `aws-actions/configure-aws-credentials`
- OIDC permissions
- branch and environment deployment strategies
- plan vs apply separation
- environment approvals

### 10.4 AWS S3 Static Hosting Guide

This should include:
- public access blocks
- bucket policies
- website configuration
- bucket and object permissions
- CloudFront integration for production hosting

### 10.5 AWS Troubleshooting Guide

This should include:
- `AccessDenied`
- `BucketAlreadyOwnedByYou`
- `Resource already managed by Terraform`
- IAM trust policy mismatch
- CloudTrail investigation approach

### 10.6 Terraform Best Practices Guide

This should cover:
- remote state
- pinning providers and versions
- approval paths
- workspace separation
- modules
- variable and output handling
- `terraform fmt` and `terraform validate`

---

## 11. Recommended next projects to build

These projects will build on this exercise and deepen your AWS/Terraform understanding.

### 11.1 Multi-environment website project

- dev, staging, production deployment roles
- separate Terraform workspaces or state keys
- environment-specific variables

### 11.2 Lambda + API Gateway project

- IAM role for Lambda execution
- Terraform-managed API gateway
- GitHub Actions deployment pipeline

### 11.3 VPC + EC2 project

- public/private subnets
- security groups
- EC2 instance deployment
- Terraform state per environment

### 11.4 RDS + application project

- relational database setup
- network configuration
- secure credentials using AWS Secrets Manager

### 11.5 CloudFront + S3 static site

- global CDN in front of S3
- TLS certificates
- caching and performance optimization

---

## 12. Best practices for future projects

- Use OIDC instead of static AWS keys for GitHub Actions
- Create one IAM role per repo/environment
- Keep Terraform state remote and encrypted
- Use a dedicated state bucket and separate state keys
- Use environment approvals for production deployments
- Keep least-privilege permissions in mind
- Avoid hardcoded AWS profiles in CI code
- Keep provider versions pinned
- Use GitHub environments and repo branch filtering
- Investigate AWS API failures using CloudTrail

---

## 13. Final takeaway

The reusable pattern from this project is:

```text
Developer commits code
-> GitHub Actions workflow triggers
-> OIDC authenticates to AWS
-> proper IAM role is assumed
-> Terraform runs against remote state in S3
-> AWS resources are created or updated safely
-> state is maintained and locked
```

This pattern is not just for static websites — it is a foundation for nearly every AWS IaC deployment you will do in the future.

---

## 14. Suggested future guide topics to create next

Priority order:

1. AWS IAM + trust policy guide
2. Terraform state and remote backend guide
3. GitHub Actions + AWS OIDC guide
4. S3 static website deployment guide
5. Debugging CloudTrail + terraform state guide

These guides will help you build a strong reusable study library.

---

This model is reusable and scalable for future AWS and Terraform projects.
