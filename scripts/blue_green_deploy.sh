#!/bin/bash
set -eo pipefail

echo "#############################################"
echo "  Blue/Green Deployment Script             "
echo "#############################################"

# Environment variables that should be passed to the script (e.g., from Jenkins)
APP_NAMESPACE="demo-dev" # 

if [ -z "$ECR_REPO_URL" ]; then
    echo "Error: ECR_REPO_URL not provided. Aborting."
    exit 1
fi
if [ -z "$NEW_APP_VERSION" ]; then
    echo "Error: NEW_APP_VERSION not provided. Aborting."
    exit 1
fi

echo "Deploying new version: ${NEW_APP_VERSION} to namespace '${APP_NAMESPACE}'"
echo "ECR Repository URL: ${ECR_REPO_URL}"

# --- Determine Current Live Version (Blue or Green) ---
CURRENT_LIVE_COLOR=$(kubectl get svc nodejs-app-service -n "${APP_NAMESPACE}" -o jsonpath='{.spec.selector.version}')
echo "Current live application version (color): ${CURRENT_LIVE_COLOR}"

if [ "${CURRENT_LIVE_COLOR}" == "blue" ]; then
    OLD_COLOR="blue"
    NEW_COLOR="green"
elif [ "${CURRENT_LIVE_COLOR}" == "green" ]; then
    OLD_COLOR="green"
    NEW_COLOR="blue"
else
    echo "Error: Unknown current live color. Expected 'blue' or 'green'. Found: ${CURRENT_LIVE_COLOR}. Aborting."
    exit 1
fi

echo "Old deployment color: ${OLD_COLOR}"
echo "New deployment color: ${NEW_COLOR}"

# --- 1. Scale up the new deployment (Green/Blue) ---
echo "Scaling up the new deployment (${NEW_COLOR}) in namespace '${APP_NAMESPACE}'..."

# Modify the deployment YAML for the new color with the new image version
NEW_DEPLOYMENT_FILE="/tmp/app-${NEW_COLOR}-temp.yaml"
cp "app/app-${NEW_COLOR}.yaml" "${NEW_DEPLOYMENT_FILE}"
sed -i "s|<ECR_REPO_URL>|${ECR_REPO_URL}|g" "${NEW_DEPLOYMENT_FILE}"
sed -i "s|APP_VERSION=2.0.0|APP_VERSION=${NEW_APP_VERSION}|g" "${NEW_DEPLOYMENT_FILE}" # Update version in the new deployment

kubectl apply -f "${NEW_DEPLOYMENT_FILE}"

# Scale the new deployment to desired replicas (e.g., 1)
kubectl scale deployment/nodejs-app-"${NEW_COLOR}" --replicas=1 -n "${APP_NAMESPACE}"

echo "Waiting for new deployment (${NEW_COLOR}) to be ready in namespace '${APP_NAMESPACE}'..."
kubectl rollout status deployment/nodejs-app-"${NEW_COLOR}" -n "${APP_NAMESPACE}" --timeout=300s
if [ $? -ne 0 ]; then
    echo "New deployment (${NEW_COLOR}) failed to become ready. Aborting deployment."
    exit 1
fi
echo "New deployment (${NEW_COLOR}) is ready."

# --- 2. Shift traffic to the new deployment ---
echo "Shifting traffic to the new deployment (${NEW_COLOR}) in namespace '${APP_NAMESPACE}'..."

# Patch the service selector to point to the new deployment's label
kubectl patch service nodejs-app-service -n "${APP_NAMESPACE}" -p "{\"spec\":{\"selector\":{\"version\":\"${NEW_COLOR}\"}}}"

echo "Traffic shifted to ${NEW_COLOR}."

# --- 3. Verification (Optional but Recommended) ---
echo "Performing post-deployment verification (e.g., hit the endpoint)..."
APP_LB_HOSTNAME=$(kubectl get svc nodejs-app-service -n "${APP_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
if [[ -z "$APP_LB_HOSTNAME" ]]; then
    echo "Could not retrieve app LoadBalancer hostname for verification."
else
    for i in {1..5}; do
        RESPONSE=$(curl -s "http://${APP_LB_HOSTNAME}/")
        echo "App response: ${RESPONSE}"
        if echo "${RESPONSE}" | grep -q "Version: ${NEW_APP_VERSION}"; then
            echo "Verification successful! New version ${NEW_APP_VERSION} is live."
            break
        fi
        sleep 5
    done
fi

# --- 4. Scale down the old deployment ---
echo "Scaling down the old deployment (${OLD_COLOR}) in namespace '${APP_NAMESPACE}'..."
kubectl scale deployment/nodejs-app-"${OLD_COLOR}" --replicas=0 -n "${APP_NAMESPACE}"
echo "Old deployment (${OLD_COLOR}) scaled down."

echo "Blue/Green deployment completed successfully!"
echo "Current live version is now: ${NEW_APP_VERSION} on ${NEW_COLOR} deployment."