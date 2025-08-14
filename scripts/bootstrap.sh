#!/bin/bash
set -eo pipefail
export AWS_PROFILE=k8s-pipeline-admin 


echo "#############################################"
echo "  EKS Blue/Green Pipeline Bootstrap Script "
echo "  (Using Local Terraform State)             "
echo "#############################################"

# --- Configuration Variables ---
DEFAULT_ENVIRONMENT="dev"
DEFAULT_AWS_REGION="ap-south-1" 
PROJECT_NAME="k8s-pipeline" 
APP_NAMESPACE="demo-dev" 

# --- Parse Arguments ---
ENVIRONMENT="${DEFAULT_ENVIRONMENT}"
AWS_REGION="${DEFAULT_AWS_REGION}"

while getopts "e:r:" opt ; do
  case $opt in
    e) ENVIRONMENT="$OPTARG" ;;
    r) AWS_REGION="$OPTARG" ;;
    \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done

echo "Targeting Environment: ${ENVIRONMENT}"
echo "Targeting AWS Region: ${AWS_REGION}"
echo "Application Namespace: ${APP_NAMESPACE}"

# --- Prerequisites Check ---
REQUIRED_COMMANDS=("terraform" "aws" "kubectl" "helm" "jq" "docker" "eksctl" "curl")
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo >&2 "${cmd} is not installed. Please install it and try again. Aborting."
        exit 1
    }
done

# AWS CLI configuration check
if ! aws configure list &>/dev/null; then
    echo "AWS CLI is not configured. Please run 'aws configure' to set up your credentials. Aborting."
    exit 1
fi

# Retrieve AWS Account ID using the specified profile
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile "${AWS_PROFILE}")
echo "AWS Account ID: ${AWS_ACCOUNT_ID}"

# --- Prompt for Jenkins Admin Password ONCE ---
echo -n "Please enter a strong password for Jenkins admin (will be used for secret creation): "
read -s JENKINS_ADMIN_PASSWORD
echo # Add a newline after password input
export JENKINS_ADMIN_PASSWORD # Export to make it available to install_jenkins.sh

# --- Terraform Deployment ---
echo "Initializing and applying Terraform for ${ENVIRONMENT} environment (using local state)..."
cd terraform
terraform init
# Plan and Apply infrastructure
terraform plan -var-file="envs/${ENVIRONMENT}/terraform.tfvars" -var="environment=${ENVIRONMENT}" -out="tfplan_${ENVIRONMENT}"
terraform apply "tfplan_${ENVIRONMENT}"

# Get Terraform Outputs (EKS Cluster Name and ECR Repo URL are essential)
EKS_CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
ECR_REPO_URL=$(terraform output -raw ecr_repository_url)

# Extract base ECR URL for manifest updates
MY_ECR_BASE=$(echo "${ECR_REPO_URL}" | awk -F'/' '{print $1 "/" $2 "/" $3}')
echo "My Private ECR Base URL: ${MY_ECR_BASE}"
cd .. 

echo "Terraform applied successfully. EKS Cluster: ${EKS_CLUSTER_NAME}, ECR Repo: ${ECR_REPO_URL}"

# --- Configure kubectl and Wait for EKS Control Plane Readiness ---
echo "Configuring kubectl to connect to the EKS cluster..."
# Update kubeconfig for the newly created EKS cluster using the specified profile
aws eks update-kubeconfig --name "${EKS_CLUSTER_NAME}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}"

echo "Verifying and waiting for kubectl access to EKS cluster..."
# Retry loop to wait for the EKS control plane to become fully responsive
MAX_KUBECTL_RETRIES=20 # Retry for up to 10 minutes (20 * 30 seconds)
KUBECTL_RETRY_COUNT=0
until kubectl get svc -n kube-system &>/dev/null; do
    if [ "${KUBECTL_RETRY_COUNT}" -ge "${MAX_KUBECTL_RETRIES}" ]; then
        echo "Error: Timed out waiting for kubectl access to EKS cluster '${EKS_CLUSTER_NAME}'."
        echo "Please check EKS cluster status in AWS console and try again."
        exit 1
    fi
    echo "kubectl not yet responsive. Retrying in 30 seconds... (Attempt $((KUBECTL_RETRY_COUNT + 1))/${MAX_KUBECTL_RETRIES})"
    sleep 30
    KUBECTL_RETRY_COUNT=$((KUBECTL_RETRY_COUNT + 1))
done
echo "kubectl configured successfully and connected to cluster: ${EKS_CLUSTER_NAME}"

# This must happen before any iamserviceaccount is created.
echo "Associating IAM OIDC provider with EKS cluster (if not already associated)..."
eksctl utils associate-iam-oidc-provider \
    --cluster="${EKS_CLUSTER_NAME}" \
    --approve \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}"
echo "IAM OIDC provider association complete."

# This patches the aws-node DaemonSet to configure the CNI for better IP allocation.
echo "Patching aws-node DaemonSet for robust IP address allocation..."
kubectl patch daemonset aws-node -n kube-system -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"aws-node","env":[{"name":"WARM_IP_TARGET","value":"3"},{"name":"MINIMUM_IP_TARGET","value":"2"},{"name":"IP_ADDITION_TIMEOUT","value":"120"},{"name":"MIN_IP_PER_NODE","value":"5"}]}]}}}}'

echo "Waiting for aws-node DaemonSet to restart after patching..."
kubectl rollout restart daemonset/aws-node -n kube-system
kubectl rollout status daemonset/aws-node -n kube-system --timeout=5m
echo "aws-node DaemonSet patched and restarted."

# --- Create Application Namespace ---
echo "Creating application namespace '${APP_NAMESPACE}'..."
kubectl apply -f app/namespace.yaml

# --- Deploy AWS EBS CSI Driver (CRITICAL FOR PVCs like Jenkins's storage) ---
echo "Creating IRSA IAM Role and ServiceAccount for EBS CSI Driver manually..."

# Get OIDC ID from the cluster's OIDC issuer URL
OIDC_ID=$(aws eks describe-cluster \
    --name "${EKS_CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query "cluster.identity.oidc.issuer" \
    --output text \
    --profile "${AWS_PROFILE}" | awk -F '/' '{print $NF}')

if [ -z "$OIDC_ID" ]; then
    echo "❌ Failed to retrieve OIDC ID from EKS Cluster. Aborting."
    exit 1
fi
echo "✅ OIDC ID: ${OIDC_ID}"

EBS_CSI_ROLE_NAME="eksctl-${EKS_CLUSTER_NAME}-addon-ebs-csi-controller-sa"
TRUST_POLICY_FILE="/tmp/ebs-csi-trust-policy.json"

cat > "${TRUST_POLICY_FILE}" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }
  ]
}
EOF

# Check if role exists
ROLE_EXISTS=$(aws iam get-role --role-name "${EBS_CSI_ROLE_NAME}" --profile "${AWS_PROFILE}" 2>/dev/null || echo "notfound")

if [[ "$ROLE_EXISTS" == "notfound" ]]; then
    echo "Creating IAM Role: ${EBS_CSI_ROLE_NAME}..."
    aws iam create-role \
        --role-name "${EBS_CSI_ROLE_NAME}" \
        --assume-role-policy-document "file://${TRUST_POLICY_FILE}" \
        --description "IRSA role for AWS EBS CSI Driver" \
        --profile "${AWS_PROFILE}" || {
            echo "❌ Failed to create IAM role. Aborting."
            exit 1
        }
else
    echo "ℹ️ IAM Role '${EBS_CSI_ROLE_NAME}' already exists. Skipping creation."
fi

# Attach AWS managed EBS CSI policy
echo "Attaching AmazonEBSCSIDriverPolicy to the role..."
aws iam attach-role-policy \
    --role-name "${EBS_CSI_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
    --profile "${AWS_PROFILE}" || {
        ATTACH_POLICY_STATUS=$?
        if [ ${ATTACH_POLICY_STATUS} -eq 254 ]; then
            echo "Policy already attached. Continuing..."
        else
            echo "Error attaching policy: aws iam attach-role-policy exited with ${ATTACH_POLICY_STATUS}. Aborting."
            exit ${ATTACH_POLICY_STATUS}
        fi
    }

# Try to attach custom policy, create if missing

echo Try to attach custom policy, create if missing
CUSTOM_POLICY_NAME="CustomEBSVolumePolicy"
CUSTOM_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${CUSTOM_POLICY_NAME}"

CUSTOM_POLICY_DOC="/tmp/custom-ebs-policy.json"

cat > "${CUSTOM_POLICY_DOC}" <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AttachVolume",
                "ec2:DetachVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot",
                "ec2:DescribeVolumes",
                "ec2:DescribeSnapshots",
                "ec2:CreateTags",
                "ec2:DeleteTags"
            ],
            "Resource": "*"
        }
    ]
}
EOF

POLICY_EXISTS=$(aws iam get-policy --policy-arn "${CUSTOM_POLICY_ARN}" --profile "${AWS_PROFILE}" 2>/dev/null || echo "notfound")

if [[ "$POLICY_EXISTS" == "notfound" ]]; then
    echo "Creating custom IAM policy: ${CUSTOM_POLICY_NAME}..."
    aws iam create-policy \
        --policy-name "${CUSTOM_POLICY_NAME}" \
        --policy-document "file://${CUSTOM_POLICY_DOC}" \
        --profile "${AWS_PROFILE}" || {
            echo "❌ Failed to create CustomEBSVolumePolicy. Skipping."
            CUSTOM_POLICY_ARN=""
        }
else
    echo "ℹ️ Custom IAM policy '${CUSTOM_POLICY_NAME}' already exists."
fi

if [ -n "${CUSTOM_POLICY_ARN}" ]; then
    echo "Attaching custom policy '${CUSTOM_POLICY_NAME}' to role '${EBS_CSI_ROLE_NAME}'..."
    aws iam attach-role-policy \
        --role-name "${EBS_CSI_ROLE_NAME}" \
        --policy-arn "${CUSTOM_POLICY_ARN}" \
        --profile "${AWS_PROFILE}" || echo "⚠️ Failed to attach ${CUSTOM_POLICY_NAME}."
fi

# Wait for role ARN
echo "Waiting for IAM Role '${EBS_CSI_ROLE_NAME}' to become available..."
EBS_CSI_SERVICE_ACCOUNT_ROLE_ARN=""
RETRIES=0
MAX_RETRIES=60
until [ -n "$EBS_CSI_SERVICE_ACCOUNT_ROLE_ARN" ]; do
    if [ "${RETRIES}" -ge "${MAX_RETRIES}" ]; then
        echo "❌ IAM Role '${EBS_CSI_ROLE_NAME}' not visible after retries. Aborting."
        exit 1
    fi

    EBS_CSI_SERVICE_ACCOUNT_ROLE_ARN=$(aws iam get-role --role-name "${EBS_CSI_ROLE_NAME}" --query 'Role.Arn' --output text --profile "${AWS_PROFILE}" 2>/dev/null || echo "")
    if [ -z "$EBS_CSI_SERVICE_ACCOUNT_ROLE_ARN" ]; then
        echo "⏳ Waiting... (${RETRIES}/${MAX_RETRIES})"
        sleep 5
    fi
    RETRIES=$((RETRIES + 1))
done

echo "✅ IAM Role ARN: ${EBS_CSI_SERVICE_ACCOUNT_ROLE_ARN}"

# Delete existing ServiceAccount to let Helm create it properly
echo "Deleting existing 'ebs-csi-controller-sa' to avoid Helm ownership conflict..."
kubectl delete serviceaccount ebs-csi-controller-sa -n kube-system --ignore-not-found

echo "Creating ServiceAccount 'ebs-csi-controller-sa' in kube-system namespace..."
kubectl create serviceaccount ebs-csi-controller-sa -n kube-system --dry-run=client -o yaml | kubectl apply -f -
echo "ServiceAccount 'ebs-csi-controller-sa' created."

# Install AWS EBS CSI Driver via Helm ---
echo "Installing AWS EBS CSI Driver via Helm..."
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver --force-update
helm repo update

helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa \
  --set "controller.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${EBS_CSI_SERVICE_ACCOUNT_ROLE_ARN}" \
  --set node.tolerateAllTaints=true \
  --set "storageClasses[0].name=ebs-sc" \
  --set "storageClasses[0].provisioner=ebs.csi.aws.com" \
  --set "storageClasses[0].reclaimPolicy=Delete" \
  --set "storageClasses[0].volumeBindingMode=WaitForFirstConsumer" \
  --set "storageClasses[0].default=true" \
  --set "storageClasses[0].parameters.type=gp2" \
  --set "storageClasses[0].allowVolumeExpansion=true" \
  --set controller.resources.requests.cpu="100m" \
  --set controller.resources.requests.memory="192Mi" \
  --set controller.resources.limits.cpu="200m" \
  --set controller.resources.limits.memory="384Mi"

# Wait Patching ServiceAccount. 
echo "Patching ServiceAccount 'ebs-csi-controller-sa' with IAM Role ARN..."
kubectl annotate serviceaccount \
  ebs-csi-controller-sa \
  -n kube-system \
  eks.amazonaws.com/role-arn="${EBS_CSI_SERVICE_ACCOUNT_ROLE_ARN}" \
  --overwrite

echo "✅ IRSA is now active on 'ebs-csi-controller-sa'. Restarting EBS CSI controller..."

kubectl rollout restart deployment ebs-csi-controller -n kube-system
kubectl rollout status deployment ebs-csi-controller -n kube-system --timeout=5m

# This ensures ServiceAccount is annotated and RBAC permissions are explicitly correct.
EBS_CSI_RBAC_FINAL_YAML="/tmp/ebs_csi_rbac_final.yaml"
echo "Generating final EBS CSI Driver RBAC manifests and applying..."
cp scripts/ebs_csi_rbac.yaml "${EBS_CSI_RBAC_FINAL_YAML}"
sed -i '' -E "s|<EBS_CSI_ROLE_ARN_PLACEHOLDER>|${EBS_CSI_SERVICE_ACCOUNT_ROLE_ARN}|g" "${EBS_CSI_RBAC_FINAL_YAML}"
kubectl apply -f "${EBS_CSI_RBAC_FINAL_YAML}"
echo "EBS CSI Driver RBAC applied."
rm "${EBS_CSI_RBAC_FINAL_YAML}" # Clean up temp file

# Wait for pods (EBS CSI Controller to stabilize)
echo "Waiting for EBS CSI Driver pods to stabilize after RBAC application..."
# Give it a bit more time after RBAC is applied for leader election to settle
sleep 30
kubectl rollout status deployment ebs-csi-controller -n kube-system --timeout=5m || true
kubectl rollout status daemonset ebs-csi-node -n kube-system --timeout=5m || true
echo "EBS CSI Driver pods stabilization check complete."

# --- Set EBS CSI driver as default StorageClass (Consolidated) ---
echo "Verifying and enforcing default StorageClass configuration..."
# Unset default from all StorageClasses (if any)
for sc in $(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}'); do
  echo "Removing default annotation from $sc (if exists)..."
  kubectl annotate storageclass "$sc" storageclass.kubernetes.io/is-default-class- --overwrite || true
done
# Set 'ebs-sc' as the default
echo "Setting 'ebs-sc' as the default StorageClass..."
kubectl annotate storageclass ebs-sc storageclass.kubernetes.io/is-default-class=true --overwrite

# Wait for pods
sleep 20 # Give some time for pods to start
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver

# --- AGGRESSIVE SCALING DOWN FOR T3.SMALL (CRITICAL) ---
echo "Scaling down CoreDNS to 1 replica to free up pod capacity on t3.small nodes..."
kubectl scale deployment coredns -n kube-system --replicas=1 || { echo "WARNING: Could not scale CoreDNS. Check manually."; }
sleep 5

echo "Scaling down EBS CSI Controller to 1 replica to free up pod capacity on t3.small nodes..."
kubectl scale deployment ebs-csi-controller -n kube-system --replicas=1 || { echo "WARNING: Could not scale EBS CSI Controller. Check manually."; }
sleep 5
# --- END AGGRESSIVE SCALING ---
kubectl get clusterroles -l app.kubernetes.io/name=aws-ebs-csi-driver -o yaml
kubectl get clusterrolebindings -l app.kubernetes.io/name=aws-ebs-csi-driver -o yaml

# Set EBS CSI driver as default StorageClass
echo "Verifying and enforcing default StorageClass configuration..."

# Unset default from all StorageClasses (if any)
for sc in $(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}'); do
  echo "Removing default annotation from $sc (if exists)..."
  kubectl annotate storageclass "$sc" storageclass.kubernetes.io/is-default-class- --overwrite || true
done

# Set 'ebs-sc' as the default
echo "Setting 'ebs-sc' as the default StorageClass..."
kubectl annotate storageclass ebs-sc storageclass.kubernetes.io/is-default-class=true --overwrite
echo "Setting 'ebs-sc' as the default StorageClass..."
kubectl annotate storageclass ebs-sc storageclass.kubernetes.io/is-default-class=true --overwrite # <--- CORRECTED LINE!
# Verify that ebs-sc is indeed the default
MAX_SC_RETRIES=10
SC_RETRY_COUNT=0
until kubectl get storageclass ebs-sc -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' | grep -q "true"; do
    if [ ${SC_RETRY_COUNT} -ge ${MAX_SC_RETRIES} ]; then
        echo "Error: 'ebs-sc' did not become the default StorageClass after multiple attempts. Aborting."
        kubectl get storageclass # Show current state
        exit 1
    fi
    echo "'ebs-sc' not yet default. Retrying in 5 seconds... (Attempt $((SC_RETRY_COUNT + 1))/${MAX_SC_RETRIES})"
    sleep 5
    SC_RETRY_COUNT=$((SC_RETRY_COUNT + 1))
done
echo "'ebs-sc' successfully set as the default StorageClass."

# Show final StorageClass configuration
kubectl get storageclass

# --- Step 5: Confirm Installation ---
echo "Verifying installation..."
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
echo "Waiting for EBS CSI Driver pods to be ready..."
kubectl rollout status deployment ebs-csi-controller -n kube-system --timeout=10m
kubectl rollout status daemonset ebs-csi-node -n kube-system --timeout=10m
echo "EBS CSI Driver pods are ready."

# --- Custom Jenkins Image Build and Push ---
echo "--- Building and pushing custom Jenkins Docker image ---"

# Define Jenkins custom image details
JENKINS_ECR_REPO_NAME="jenkins-custom"
JENKINS_ECR_REPO_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${JENKINS_ECR_REPO_NAME}"
JENKINS_IMAGE_TAG="lts-$(date +%Y%m%d%H%M%S%3N)" 
JENKINS_DOCKERFILE_DIR="./jenkins" 

# This variable will hold the final fully qualified image URL (e.g., repo/image:tag)
JENKINS_ECR_FULL_IMAGE="${JENKINS_ECR_REPO_URL}:${JENKINS_IMAGE_TAG}"

echo "===> Jenkins ECR Repository URL: ${JENKINS_ECR_REPO_URL}"
echo "===> Jenkins Docker Image Tag: ${JENKINS_IMAGE_TAG}"
echo "===> Full Jenkins Image URI: ${JENKINS_ECR_FULL_IMAGE}"

# Create Jenkins ECR repository if it doesn't exist
echo "Ensuring ECR repository '${JENKINS_ECR_REPO_NAME}' exists..."
aws ecr describe-repositories --repository-names "${JENKINS_ECR_REPO_NAME}" --region "${AWS_REGION}" > /dev/null 2>&1 || \
aws ecr create-repository --repository-name "${JENKINS_ECR_REPO_NAME}" --region "${AWS_REGION}"

# Login to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${JENKINS_ECR_REPO_URL}"
echo "Building and pushing Jenkins Docker image to ECR using docker buildx..."
docker buildx build \
  --platform linux/amd64 \
  -t "${JENKINS_ECR_FULL_IMAGE}" \
  --push \
  -f "${JENKINS_DOCKERFILE_DIR}/Dockerfile" \
  "${JENKINS_DOCKERFILE_DIR}"

echo "✅ Custom Jenkins image built and pushed successfully: ${JENKINS_ECR_FULL_IMAGE}"

# --- Deploy Jenkins to Kubernetes (Using kubectl apply -f with dynamic replacement) ---
echo "--- Deploying Jenkins to Kubernetes from YAML ---"

# Define Jenkins K8s YAML path
JENKINS_YAML_TEMPLATE_PATH="./jenkins/k8s/jenkins-deployment.yaml" # Your static YAML with placeholder
JENKINS_DEPLOYMENT_YAML_FINAL="/tmp/jenkins-deployment-final-$(date +%s).yaml" # Temporary file for final YAML

# 1. Clean up old Jenkins resources
JENKINS_NAMESPACE="jenkins"

# 2. Recreate Jenkins Namespace
echo "Creating Jenkins namespace '${JENKINS_NAMESPACE}'..."
kubectl create namespace "${JENKINS_NAMESPACE}" || true
sleep 2

# 3. Create Jenkins Admin Credentials Secret
echo "Creating Jenkins admin credentials secret..."
kubectl create secret generic jenkins-admin-credentials --namespace "${JENKINS_NAMESPACE}" \
  --from-literal=jenkins-admin-user=admin \
  --from-literal=jenkins-admin-password="${JENKINS_ADMIN_PASSWORD}" --dry-run=client -o yaml | kubectl apply -f -
echo "Jenkins admin credentials secret created."

# 4. Deploy Jenkins RBAC for application namespace (for Jenkins to deploy apps later)
echo "Applying Jenkins Kubernetes RBAC for application namespace '${APP_NAMESPACE}'..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-app-deployer
  namespace: ${APP_NAMESPACE}
rules:
  - apiGroups: ["", "apps", "extensions", "networking.k8s.io"]
    resources: ["deployments", "services", "ingresses", "pods", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: [""]
    resources: ["secrets", "configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-app-deployer-binding
  namespace: ${APP_NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: ${JENKINS_NAMESPACE} # Reference to the Jenkins SA in its own namespace
roleRef:
  kind: Role
  name: jenkins-app-deployer
  apiGroup: rbac.authorization.k8s.io
EOF
echo "Jenkins RBAC applied."

# 5. Generate final Jenkins deployment YAML by replacing placeholder
echo "Generating final Jenkins deployment YAML by replacing placeholder with actual image URI..."
cp "${JENKINS_YAML_TEMPLATE_PATH}" "${JENKINS_DEPLOYMENT_YAML_FINAL}"
# Replace the placeholder {{JENKINS_IMAGE_URI}} with the actual dynamic image URI
sed -i '' -E "s|{{JENKINS_IMAGE_URI}}|${JENKINS_ECR_FULL_IMAGE}|g" "${JENKINS_DEPLOYMENT_YAML_FINAL}"

# 6. Apply the final YAML
echo "Applying Jenkins deployment manifests from ${JENKINS_DEPLOYMENT_YAML_FINAL}..."
kubectl apply -f "${JENKINS_DEPLOYMENT_YAML_FINAL}"
echo "Jenkins deployment manifests applied."

# Clean up the temporary final YAML file
rm "${JENKINS_DEPLOYMENT_YAML_FINAL}"

# Wait for Jenkins pod to be ready
echo "Waiting for Jenkins pod to be ready..."
# Use rollout status on StatefulSet to wait for it to stabilize
kubectl rollout status statefulset jenkins -n "${JENKINS_NAMESPACE}" --timeout=15m || { echo "Jenkins StatefulSet failed to rollout. Check logs for details."; exit 1; }

# Get Jenkins LoadBalancer URL
echo "Waiting for Jenkins LoadBalancer to be provisioned..."
JENKINS_LB_HOSTNAME=""
for i in {1..40}; do # Loop up to 20 minutes (40*30s) for LB
    JENKINS_LB_HOSTNAME=$(kubectl get svc jenkins -n "${JENKINS_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [[ -n "$JENKINS_LB_HOSTNAME" ]]; then
        break
     fi
    echo "Still waiting for Jenkins LoadBalancer hostname..."
    sleep 30
done

if [[ -z "$JENKINS_LB_HOSTNAME" ]]; then
    echo "Timed out waiting for Jenkins LoadBalancer hostname. Check 'kubectl get svc jenkins -n ${JENKINS_NAMESPACE}'."
else
    echo "Jenkins is available at: http://${JENKINS_LB_HOSTNAME}"
    echo "Initial Jenkins admin password can be retrieved using 'kubectl exec' command: "
    echo "kubectl exec --namespace ${JENKINS_NAMESPACE} -it svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password && echo"
    echo "You may need to wait a few more minutes for Jenkins UI to be fully accessible."
fi

# --- Build and Push Node.js App to ECR ---
echo "--- Building Node.js app Docker image and pushing to ECR ---"
APP_VERSION="1.0.0" 

# Define Node.js app image details
NODEJS_APP_ECR_REPO_URL="${ECR_REPO_URL}" 
NODEJS_APP_FULL_IMAGE_URI="${NODEJS_APP_ECR_REPO_URL}:${APP_VERSION}" 
NODEJS_APP_DOCKERFILE_DIR="./app" 

echo "Node.js App ECR Image URI: ${NODEJS_APP_FULL_IMAGE_URI}"

cd "${NODEJS_APP_DOCKERFILE_DIR}" 

echo pwd

# Login to ECR
aws ecr get-login-password --region "${AWS_REGION}" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# --- CRITICAL CHANGE: Use docker buildx build with --platform ---
echo "Building and pushing Node.js App Docker image for linux/amd64 to ECR using docker buildx..."
docker buildx build --platform linux/amd64 -t "${NODEJS_APP_FULL_IMAGE_URI}" --push "."
cd .. # Go back to the project root
echo "Node.js app v${APP_VERSION} pushed to ECR."

# --- Deploy Initial Node.js App (Blue) ---
echo "Deploying initial (Blue) Node.js application to namespace '${APP_NAMESPACE}'..."

# Replace placeholders in the blue deployment manifest with actual ECR URL and app version
sed "s|<ECR_REPO_URL>|${ECR_REPO_URL}|g; s|APP_VERSION=1.0.0|APP_VERSION=${APP_VERSION}|g" \
    app/app-blue.yaml > /tmp/app-blue-final.yaml

# Apply the blue deployment
kubectl apply -f /tmp/app-blue-final.yaml

# Apply the Node.js application service
kubectl apply -f app/service.yaml

echo "Waiting for Node.js app (Blue) deployment to be ready in namespace '${APP_NAMESPACE}'..."
kubectl rollout status deployment/nodejs-app-blue -n "${APP_NAMESPACE}" --timeout=300s

echo "Node.js app (Blue) deployed. Waiting for LoadBalancer..."
APP_LB_HOSTNAME=""
for i in {1..20}; do # Loop up to 10 minutes (20 * 30s) to wait for LoadBalancer hostname
    APP_LB_HOSTNAME=$(kubectl get svc nodejs-app-service -n "${APP_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [[ -n "$APP_LB_HOSTNAME" ]]; then
        break
     fi
    echo "Still waiting for Node.js app LoadBalancer hostname..."
    sleep 30
done

if [[ -z "$APP_LB_HOSTNAME" ]]; then
    echo "Timed out waiting for Node.js app LoadBalancer hostname. Check 'kubectl get svc nodejs-app-service -n ${APP_NAMESPACE}'."
else
    echo "Node.js app (Blue) is available at: http://${APP_LB_HOSTNAME}"
fi

# Deploy the green deployment scaled to 0 initially
echo "Deploying Node.js app (Green) with 0 replicas initially to namespace '${APP_NAMESPACE}'..."
# This deployment is ready to be scaled up during a blue/green deployment
sed "s|<ECR_REPO_URL>|${ECR_REPO_URL}|g; s|APP_VERSION=2.0.0|APP_VERSION=2.0.0|g" \
    app/app-green.yaml > /tmp/app-green-initial.yaml
kubectl apply -f /tmp/app-green-initial.yaml
echo "Node.js app (Green) deployment created with 0 replicas."
echo "Bootstrap complete!"
echo "Next, configure Jenkins and the blue/green deployment pipeline."
echo "Remember to monitor your AWS Free Tier usage to avoid unexpected charges, especially from Load Balancers."
echo "Your Terraform state file is located at: k8s-bluegreen-pipeline/terraform/terraform.tfstate"
