#!/bin/bash
set -eo pipefail
export AWS_PROFILE=k8s-pipeline-admin

echo "#############################################"
echo "  EKS Blue/Green Deployment Teardown Script"
echo "  (Using Local Terraform State)             "
echo "#############################################"

# --- Variables 
AWS_REGION=${AWS_REGION:-"ap-south-1"} 
ENVIRONMENT=${ENVIRONMENT:-"dev"}
PROJECT_NAME=${PROJECT_NAME:-"k8s-pipeline"}
EKS_CLUSTER_NAME="${PROJECT_NAME}-${ENVIRONMENT}-eks"
ECR_REPO_NAME="${PROJECT_NAME}/${ENVIRONMENT}/nodejs-app"
APP_NAMESPACE="demo-dev" 

read -p "Are you sure you want to destroy ALL resources for environment '${ENVIRONMENT}' in region '${AWS_REGION}'? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Teardown aborted."
    exit 0
fi

echo "Starting Kubernetes resource deletion..."

# Delete Jenkins Helm release
echo "Deleting Jenkins Helm release..."
helm uninstall jenkins -n jenkins --ignore-not-found || true

# Delete Jenkins namespace (This will cascade delete Jenkins PVCs, StatefulSets, Services, Secrets, etc.
echo "Deleting Jenkins namespace..."
kubectl delete namespace jenkins --force --grace-period=0 --ignore-not-found=true || true
echo "Deleting application namespace '${APP_NAMESPACE}'..."
kubectl delete namespace "${APP_NAMESPACE}" --force --grace-period=0 --ignore-not-found=true || true

# Delete the EBS CSI Driver addon using eksctl (This implicitly deletes the EBS CSI controller pod, SA, RBAC etc.)
echo "Deleting AWS EBS CSI Driver addon (if managed by eksctl)..."
eksctl delete addon \
    --name aws-ebs-csi-driver \
    --cluster "${EKS_CLUSTER_NAME}" \
    --profile ${AWS_PROFILE} \
    --region "${AWS_REGION}" || true

# NOTE: The following kubectl delete commands for specific CSI RBAC (ServiceAccount, ClusterRoles/Bindings)
echo "Deleting any potentially leftover EBS CSI ServiceAccount and Cluster-scoped RBAC..."
kubectl delete serviceaccount ebs-csi-controller-sa -n kube-system --ignore-not-found=true || true
kubectl delete clusterrole aws-ebs-csi-driver-leader-election --ignore-not-found || true
kubectl delete clusterrole ebs-csi-driver-leader-election-role --ignore-not-found || true # Name from manual template
kubectl delete clusterrole system:csi-external-provisioner --ignore-not-found || true
kubectl delete clusterrole system:csi-external-attacher --ignore-not-found || true
kubectl delete clusterrole system:csi-external-resizer --ignore-not-found || true
kubectl delete clusterrole aws-ebs-csi-driver-controller --ignore-not-found || true
kubectl delete clusterrole aws-ebs-csi-driver-node --ignore-not-found || true
kubectl delete clusterrolebinding aws-ebs-csi-driver-leader-election --ignore-not-found || true
kubectl delete clusterrolebinding ebs-csi-driver-leader-election-binding --ignore-not-found || true # Name from manual template
kubectl delete clusterrolebinding system:csi-external-provisioner --ignore-not-found || true
kubectl delete clusterrolebinding system:csi-external-attacher --ignore-not-found || true
kubectl delete clusterrolebinding system:csi-external-resizer --ignore-not-found || true
kubectl delete clusterrolebinding aws-ebs-csi-driver-controller --ignore-not-found || true
kubectl delete clusterrolebinding aws-ebs-csi-driver-node --ignore-not-found || true


echo "Kubernetes resources deletion initiated. Waiting for AWS Load Balancers to deprovision..."
# Give some time for ELBs to deregister and delete before Terraform runs
sleep 60

echo "Destroying Terraform-managed AWS resources..."
cd terraform
# Terraform destroy will use the local terraform.tfstate file
terraform destroy -auto-approve \
    -var-file="envs/${ENVIRONMENT}/terraform.tfvars" \
    -var="environment=${ENVIRONMENT}"

# Delete IAM Policy for EBS CSI Driver (This policy's name 'AmazonEKS_EBS_CSI_Driver_Policy_${EKS_CLUSTER_NAME}'
echo "Deleting IAM Policy for EBS CSI Driver (if custom created and not TF managed)..."
POLICY_NAME="AmazonEKS_EBS_CSI_Driver_Policy_${EKS_CLUSTER_NAME}" # Check if this is the correct name from your setup
POLICY_ARN=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text --profile ${AWS_PROFILE})
if [ -n "$POLICY_ARN" ]; then
    aws iam delete-policy --policy-arn "${POLICY_ARN}" --profile ${AWS_PROFILE} || true
else
    echo "IAM Policy '${POLICY_NAME}' not found. Skipping deletion."
fi

# Manual deletion of IAM Roles and Instance Profiles created by Terraform (iam module)
echo "Deleting IAM Instance Profiles and Roles created by Terraform (if they exist and are not managed by Terraform destroy)..."

# Instance Profile name from modules/iam/main.tf
INSTANCE_PROFILE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-eks-node-group-instance-profile"
# Role names from modules/iam/main.tf
NODE_GROUP_ROLE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-eks-node-group-role"
CLUSTER_ROLE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-eks-cluster-role"

# 1. Delete Node Group Instance Profile
echo "Checking and deleting Instance Profile '${INSTANCE_PROFILE_NAME}'..."
INSTANCE_PROFILE_EXISTS=$(aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" --profile ${AWS_PROFILE} 2>/dev/null || echo "")
if [ -n "$INSTANCE_PROFILE_EXISTS" ]; then
    # Must remove role from instance profile before deleting profile
    echo "Removing role '${NODE_GROUP_ROLE_NAME}' from instance profile '${INSTANCE_PROFILE_NAME}'..."
    aws iam remove-role-from-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" --role-name "${NODE_GROUP_ROLE_NAME}" --profile ${AWS_PROFILE} || true
    echo "Deleting instance profile '${INSTANCE_PROFILE_NAME}'..."
    aws iam delete-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" --profile ${AWS_PROFILE} || true
else
    echo "Instance Profile '${INSTANCE_PROFILE_NAME}' not found. Skipping deletion."
fi

# 2. Delete Node Group Role and its attached policies
echo "Checking and deleting Node Group Role '${NODE_GROUP_ROLE_NAME}'..."
NODE_GROUP_ROLE_EXISTS=$(aws iam get-role --role-name "${NODE_GROUP_ROLE_NAME}" --profile ${AWS_PROFILE} 2>/dev/null || echo "")
if [ -n "$NODE_GROUP_ROLE_EXISTS" ]; then
    echo "Detaching policies from role '${NODE_GROUP_ROLE_NAME}'..."
    for policy_arn in $(aws iam list-attached-role-policies --role-name "${NODE_GROUP_ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text --profile ${AWS_PROFILE}); do
        aws iam detach-role-policy --role-name "${NODE_GROUP_ROLE_NAME}" --policy-arn "${policy_arn}" --profile ${AWS_PROFILE} || true
    done
    echo "Deleting role '${NODE_GROUP_ROLE_NAME}'..."
    aws iam delete-role --role-name "${NODE_GROUP_ROLE_NAME}" --profile ${AWS_PROFILE} || true
else
    echo "Node Group Role '${NODE_GROUP_ROLE_NAME}' not found. Skipping deletion."
fi

# 3. Delete EKS Cluster Role and its attached policies
echo "Checking and deleting EKS Cluster Role '${CLUSTER_ROLE_NAME}'..."
CLUSTER_ROLE_EXISTS=$(aws iam get-role --role-name "${CLUSTER_ROLE_NAME}" --profile ${AWS_PROFILE} 2>/dev/null || echo "")
if [ -n "$CLUSTER_ROLE_EXISTS" ]; then
    echo "Detaching policies from role '${CLUSTER_ROLE_NAME}'..."
    for policy_arn in $(aws iam list-attached-role-policies --role-name "${CLUSTER_ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text --profile ${AWS_PROFILE}); do
        aws iam detach-role-policy --role-name "${CLUSTER_ROLE_NAME}" --policy-arn "${policy_arn}" --profile ${AWS_PROFILE} || true
    done
    echo "Deleting role '${CLUSTER_ROLE_NAME}'..."
    aws iam delete-role --role-name "${CLUSTER_ROLE_NAME}" --profile ${AWS_PROFILE} || true
else
    echo "EKS Cluster Role '${CLUSTER_ROLE_NAME}' not found. Skipping deletion."
fi

# Finally, delete the IAM Role created by eksctl iamserviceaccount (for CSI driver)
echo "Deleting IAM Role for EBS CSI Service Account (from eksctl, if exists)..."
EBS_CSI_ROLE_NAME="eksctl-${EKS_CLUSTER_NAME}-addon-ebs-csi-controller-sa"
EBS_CSI_ROLE_EXISTS=$(aws iam get-role --role-name "${EBS_CSI_ROLE_NAME}" --profile ${AWS_PROFILE} 2>/dev/null || echo "")
if [ -n "$EBS_CSI_ROLE_EXISTS" ]; then
    echo "Detaching policies from role '${EBS_CSI_ROLE_NAME}'..."
    for policy_arn in $(aws iam list-attached-role-policies --role-name "${EBS_CSI_ROLE_NAME}" --query 'AttachedPolicies[].PolicyArn' --output text --profile ${AWS_PROFILE}); do
        aws iam detach-role-policy --role-name "${EBS_CSI_ROLE_NAME}" --policy-arn "${policy_arn}" --profile ${AWS_PROFILE} || true
    done
    echo "Deleting role '${EBS_CSI_ROLE_NAME}'..."
    aws iam delete-role --role-name "${EBS_CSI_ROLE_NAME}" --profile ${AWS_PROFILE} || true
else
    echo "IAM Role '${EBS_CSI_ROLE_NAME}' not found. Skipping deletion."
fi


echo "Teardown complete."
echo "Verify in AWS Console that all resources (especially Load Balancers, EC2 instances, ECR, EKS cluster) are deleted."
echo "Also, note that the local Terraform state file (terraform/terraform.tfstate) remains. You can delete it manually if desired."