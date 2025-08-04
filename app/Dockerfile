# app/Dockerfile
FROM node:20-alpine

# Set the working directory in the container
WORKDIR /usr/src/app

COPY package*.json ./

# Install app dependencies
RUN npm install --production

# Copy the rest of the application source code
COPY . .

# Expose the port the app runs on
EXPOSE 3000

# Define environment variables
ENV NODE_ENV=production
ENV APP_VERSION=1.0.0

# Run the application
CMD [ "npm", "start" ]