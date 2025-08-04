FROM jenkins/jenkins:lts

USER root

# Optional: install curl
RUN apt-get update && apt-get install -y curl

# Copy the plugin 
COPY plugins.txt /usr/share/jenkins/ref/plugins.txt

# Use built-in Jenkins plugin CLI
RUN jenkins-plugin-cli --plugin-file /usr/share/jenkins/ref/plugins.txt
