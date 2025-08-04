# Kubernetes Blue/Green CI/CD Pipeline on AWS

## 1. Project Overview
This repository automates the setup of a robust CI/CD pipeline on AWS using **Terraform**, **EKS**, and **Jenkins**. It includes:

- **Infrastructure as Code (Terraform):**  
  - Provisions a dedicated VPC, EKS cluster (t3.small worker nodes), IAM roles, and ECR repositories.
- **Custom Jenkins Server:**  
  - Docker image with essential plugins (Kubernetes, Git, Docker, AWS Credentials) deployed on EKS.
- **EBS CSI Driver:**  
  - Enables dynamic persistent storage for Jenkins.
- **Blue/Green Deployment:**  
  - Demonstrates zero-downtime deployments with a sample Node.js application.

---

## 2. Prerequisites
Ensure the following tools are installed and configured locally:

- **AWS CLI (v2):** Configured with an admin profile (e.g., `k8s-pipeline-admin`)
- **Terraform (v1.x.x+)**
- **kubectl**
- **Helm (v3.x.x+)**
- **Docker Desktop / Engine:** Must support `linux/amd64` builds with `buildx` enabled
- **eksctl**
- **jq**, **curl** (usually pre-installed on Linux/macOS)

---

## 3. Deployment

### 3.1 Run the Deployment Script
1. Navigate to the project root.  
2. Make the script executable:
   ```bash
   chmod +x bootstrap.sh

Deployment typically takes 20–40 minutes.

## 4. Accessing Applications

### 4.1 Accessing Jenkins
- **Get the admin password:**
  ```bash
  kubectl exec --namespace jenkins -it svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password && echo

 Get the Jenkins URL (printed by bootstrap.sh):

### 4.2 Accessing the Node.js Application

Get the Application URL (printed by bootstrap.sh):

## 5. CI/CD with Jenkins

### 1 Configure AWS Credentials:
-  In Jenkins UI: Manage Jenkins > Manage Credentials > (global) > Add Credentials

-  Add AWS credentials with ID aws-credentials (use Access Key/Secret Key from k8s-pipeline-admin).

### 2 Create a Pipeline Job:
- Create a new Pipeline job named Nodejs-Blue-Green-Pipeline.

- Set Pipeline Definition to “Pipeline script from SCM.”

- Select Git as SCM and provide the Node.js app repository URL.

- Set Script Path to Jenkinsfile.

## 6. Teardown
  - Make the teardown script executable:
    ```bash
    chmod +x scripts/teardown.sh 
    ```bash
    ./scripts/teardown.sh
  - Confirm when prompted.
  - Teardown typically takes 20–40 minutes.

## 7. Cost Considerations
  - Uses t3.small instances for cost optimization.

  - Services like EKS Control Plane, Load Balancers, NAT Gateway, and ECR will incur charges even under the Free Tier.

  - Recommendation: Run scripts/teardown.sh when not actively using the environment. Monitor your AWS Billing Dashboard regularly.
