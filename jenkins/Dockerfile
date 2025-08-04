FROM jenkins/jenkins:lts

USER root

# Optional: install curl, if needed
RUN apt-get update && apt-get install -y curl

# Copy the plugin list
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

# Use built-in Jenkins plugin CLI
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
