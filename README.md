1. Project Overview
This repository provides an automated setup for a robust CI/CD pipeline on AWS:

Infrastructure as Code (Terraform): Provisions a dedicated VPC, EKS Cluster (t3.small worker nodes), and all necessary IAM roles and ECR repositories.

Custom Jenkins Server: A Docker image with essential plugins (Kubernetes, Git, Docker, AWS Credentials) is built and deployed on EKS for CI/CD orchestration.

EBS CSI Driver: Enables dynamic persistent storage for Jenkins.

Blue/Green Deployment: A sample Node.js application demonstrates zero-downtime deployments.

2. Prerequisites
Ensure these tools are installed and configured on your local machine:

AWS CLI (v2): Configured with an admin profile (e.g., k8s-pipeline-admin).

Terraform (v1.x.x+):

kubectl:

Helm (v3.x.x+):

Docker Desktop / Docker Engine: Must be running, with buildx enabled and supporting linux/amd64 builds.

eksctl:

jq, curl: (Usually pre-installed on Linux/macOS).

3. Deployment
The entire project is deployed using the bootstrap.sh script.

3.1: One-Time Jenkins YAML Template Setup
Before the first run, prepare the Jenkins Kubernetes YAML template:

3.2: Run the Deployment Script
Go to your project root directory.

Make bootstrap.sh executable: chmod +x bootstrap.sh

Run the script: ./bootstrap.sh

Deployment typically takes 20-40 minutes.

4. Accessing Applications
After successful deployment:

4.1: Accessing Jenkins
Get Password: kubectl exec --namespace jenkins -it svc/jenkins -c jenkins -- /bin/cat /run/secrets/additional/chart-admin-password && echo

Get URL: Look for the URL printed by bootstrap.sh: Jenkins is available at: http://<YOUR-JENKINS-LB-HOSTNAME>

4.2: Accessing Node.js Application
Get URL: Look for the URL printed by bootstrap.sh: Node.js app (Blue) is available at: http://<YOUR-NODEJS-APP-LB-HOSTNAME>

Open the URL in your browser.

5. CI/CD with Jenkins
Configure AWS Credentials in Jenkins: In Jenkins UI, go to Manage Jenkins > Manage Credentials > (global) > Add Credentials. Add AWS Credentials with ID aws-credentials (using your k8s-pipeline-admin user's Access Key ID and Secret Access Key).

Create Jenkins Pipeline Job: Create a new "Pipeline" item named Nodejs-Blue-Green-Pipeline.

Configure SCM: Set Pipeline Definition to "Pipeline script from SCM", SCM to "Git", and provide your Node.js app's Git repository URL. Set "Script Path" to Jenkinsfile.


6. Teardown
To destroy all AWS resources created by this project, run the teardown.sh script.

Go to your project root directory.

Make scripts/teardown.sh executable: chmod +x scripts/teardown.sh

Run the script: ./scripts/teardown.sh

Confirm when prompted.

Teardown typically takes 20-40 minutes.

7. Cost Considerations
This setup utilizes t3.small EC2 instances for cost optimization. However, some services (EKS Control Plane, Load Balancers, NAT Gateway, ECR) will incur charges even within the AWS Free Tier.

It is highly recommended to run scripts/teardown.sh when you are not actively using the environment to avoid unexpected AWS costs. Always monitor your AWS Billing Dashboard.