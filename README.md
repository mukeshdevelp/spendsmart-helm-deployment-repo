# SpendSmart Helm deployment (EKS)

Harbor → ECR mirror (optional), bastion SSM deploy, OT-CONTAINER-KIT **spendsmart** chart.

**Prerequisite:** infra stack from [spendsmart-infra-only-aws](https://github.com/mukeshdevelp/spendsmart-infra-only-aws) must be **CREATE_COMPLETE** with `databases` pods Ready.

| Doc | Purpose |
|-----|---------|
| [HELM-DEPLOY.md](HELM-DEPLOY.md) | Jenkins params, Harbor mirror, troubleshooting |

## Jenkins

Use root **`Jenkinsfile`** in this repo (`aws-creds`, `spendsmart-gpg-key`, optional `harbor-creds`).

## Local / PC

```sh
bash scripts/helm/mirror-harbor-to-ecr.sh   # after deploy/ecr.env + harbor.env
export GPG_KEY='...'
bash scripts/helm/run-on-bastion-via-ssm.sh scripts/helm/deploy-spendsmart-on-bastion.sh
```

URLs after deploy:

```sh
export CFN_STACK_NAME=spendsmart-dev AWS_REGION=us-east-1
eval "$(bash scripts/cfn-alb-urls.sh)"
```

Monorepo copy (unchanged layout): [CFT-spendsmart](https://github.com/mukeshdevelp/CFT-spendsmart).
