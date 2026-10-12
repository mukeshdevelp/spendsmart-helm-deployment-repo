pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '15'))
  }

  parameters {
    choice(name: 'AWS_REGION', choices: ['us-east-1', 'ap-south-1'], description: 'Stack / ECR region')
    string(name: 'CFN_STACK_NAME', defaultValue: 'spendsmart-dev', description: 'Infra stack (CREATE_COMPLETE)')
    string(name: 'CFN_TEMPLATE_BUCKET', defaultValue: 'spendsmart-cfn-packages', description: 'S3 bastion-assets bucket')
    string(name: 'NAME_PREFIX', defaultValue: 'spendsmart-dev', description: 'NamePrefix / SM path prefix')
    string(name: 'EKS_CLUSTER_NAME', defaultValue: 'spendsmart', description: 'EKS cluster name')
    booleanParam(name: 'MIRROR_TO_ECR', defaultValue: false, description: 'true only if Jenkins agent can docker login Harbor; else mirror on PC and leave false')
    string(name: 'MIRROR_AGENT_LABEL', defaultValue: '', description: 'Optional Jenkins node label for mirror only (empty = same agent as this job)')
    string(name: 'ECR_REPO_PREFIX', defaultValue: 'spendsmart', description: 'ECR repos: {prefix}/backend|frontend|engine')
    string(name: 'HARBOR_TAG', defaultValue: 'latest', description: 'Tag to pull from Harbor when mirroring')
    string(name: 'IMAGE_TAG', defaultValue: '', description: 'ECR deploy tag (empty = BUILD_NUMBER when mirroring, else latest)')
    string(name: 'CREDENTIAL_HARBOR', defaultValue: 'harbor-creds', description: 'Harbor login (mirror stage only)')
    string(name: 'CREDENTIAL_GPG_KEY', defaultValue: 'spendsmart-gpg-key', description: 'Backend GPG_KEY secret text')
    string(name: 'BASTION_INSTANCE_ID', defaultValue: '', description: 'Optional; default from stack BastionInstanceId')
  }

  environment {
    AWS_REGION = "${params.AWS_REGION}"
    AWS_DEFAULT_REGION = "${params.AWS_REGION}"
    CFN_STACK_NAME = "${params.CFN_STACK_NAME}"
    CFN_TEMPLATE_BUCKET = "${params.CFN_TEMPLATE_BUCKET}"
    NAME_PREFIX = "${params.NAME_PREFIX}"
    EKS_CLUSTER_NAME = "${params.EKS_CLUSTER_NAME}"
    ECR_REPO_PREFIX = "${params.ECR_REPO_PREFIX}"
    HARBOR_TAG = "${params.HARBOR_TAG}"
    BASTION_INSTANCE_ID = "${params.BASTION_INSTANCE_ID}"
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Resolve image tag') {
      steps {
        script {
          def p = params.IMAGE_TAG?.trim()
          if (p) {
            env.RESOLVED_IMAGE_TAG = p
          } else if (params.MIRROR_TO_ECR) {
            env.RESOLVED_IMAGE_TAG = "${env.BUILD_NUMBER}"
          } else {
            env.RESOLVED_IMAGE_TAG = 'latest'
          }
          echo "Deploy ECR tag: ${env.RESOLVED_IMAGE_TAG}"
        }
      }
    }

    stage('Mirror Harbor to ECR') {
      when { expression { return params.MIRROR_TO_ECR } }
      steps {
        script {
          def harborCred = params.CREDENTIAL_HARBOR?.trim() ?: 'harbor-creds'
          def mirrorLabel = params.MIRROR_AGENT_LABEL?.trim()
          def mirrorSh = '''
            set -eu
            command -v docker >/dev/null || { echo "docker not on this agent — set MIRROR_TO_ECR=false after PC mirror, or MIRROR_AGENT_LABEL"; exit 1; }
            test -n "${HARBOR_USERNAME:-}" || { echo "HARBOR_USERNAME empty — check Jenkins credential (Username with password)"; exit 1; }
            test -n "${HARBOR_PASSWORD:-}" || { echo "HARBOR_PASSWORD empty — update harbor-creds in Jenkins"; exit 1; }
            export HARBOR_SERVER=harbor.ldc.opstree.dev
            export IMAGE_TAG="${RESOLVED_IMAGE_TAG}"
            export ECR_REPO_PREFIX="${ECR_REPO_PREFIX}"
            export HARBOR_TAG="${HARBOR_TAG}"
            bash scripts/helm/mirror-harbor-to-ecr.sh
          '''
          def runMirror = {
            withCredentials([
              usernamePassword(credentialsId: harborCred, usernameVariable: 'HARBOR_USERNAME', passwordVariable: 'HARBOR_PASSWORD'),
            ]) {
              withAwsCredentials {
                sh mirrorSh
              }
            }
          }
          if (mirrorLabel) {
            node(mirrorLabel) {
              checkout scm
              runMirror()
            }
          } else {
            runMirror()
          }
        }
      }
    }

    stage('Preflight infra stack') {
      steps {
        script {
          withAwsCredentials {
            sh '''
            set -eu
            STATUS=$(aws cloudformation describe-stacks --stack-name "${CFN_STACK_NAME}" --region "${AWS_REGION}" \
              --query 'Stacks[0].StackStatus' --output text)
            case "$STATUS" in
              CREATE_COMPLETE|UPDATE_COMPLETE) ;;
              *) echo "Infra stack must be CREATE_COMPLETE or UPDATE_COMPLETE, got: $STATUS"; exit 1 ;;
            esac
            aws cloudformation describe-stacks --stack-name "${CFN_STACK_NAME}" --region "${AWS_REGION}" \
              --query 'Stacks[0].Outputs[?OutputKey==`BastionInstanceId`].OutputValue' --output text | grep -q .
            '''
          }
        }
      }
    }

    stage('Sync helm script to S3') {
      steps {
        script {
          withAwsCredentials {
            sh 'bash scripts/sync-helm-assets-to-s3.sh "${CFN_TEMPLATE_BUCKET}" "${AWS_REGION}"'
          }
        }
      }
    }

    stage('Deploy SpendSmart via bastion SSM') {
      steps {
        script {
          def gpgCred = params.CREDENTIAL_GPG_KEY?.trim() ?: 'spendsmart-gpg-key'
          withCredentials([
            string(credentialsId: gpgCred, variable: 'GPG_KEY'),
          ]) {
            withAwsCredentials {
              sh '''
              set -eu
              export IMAGE_TAG="${RESOLVED_IMAGE_TAG}"
              export CFN_STACK_NAME="${CFN_STACK_NAME}"
              export CFN_TEMPLATE_BUCKET="${CFN_TEMPLATE_BUCKET}"
              export NAME_PREFIX="${NAME_PREFIX}"
              export EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME}"
              export ECR_REPO_PREFIX="${ECR_REPO_PREFIX}"
              if [ -n "${BASTION_INSTANCE_ID}" ]; then export BASTION_INSTANCE_ID="${BASTION_INSTANCE_ID}"; fi
              bash scripts/helm/run-on-bastion-via-ssm.sh scripts/helm/deploy-spendsmart-on-bastion.sh
              '''
            }
          }
        }
      }
    }

    stage('URLs') {
      steps {
        script {
          withAwsCredentials {
            sh '''
            eval "$(bash scripts/cfn-alb-urls.sh)"
            echo "Frontend:  ${FRONTEND_URL}"
            echo "Backend:   ${BACKEND_URL}"
            echo "Keycloak:  ${KEYCLOAK_URL}"
            '''
          }
        }
      }
    }
  }

  post {
    failure {
      sh 'echo "Helm deploy failed — bastion: sudo tail -100 /var/log/spendsmart-helm-deploy.log"'
    }
  }
}

void withAwsCredentials(Closure body) {
  withCredentials([[
    $class: 'AmazonWebServicesCredentialsBinding',
    credentialsId: 'aws-creds',
    accessKeyVariable: 'AWS_ACCESS_KEY_ID',
    secretKeyVariable: 'AWS_SECRET_ACCESS_KEY',
  ]]) {
    body()
  }
}
