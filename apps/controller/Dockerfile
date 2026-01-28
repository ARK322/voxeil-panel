FROM node:20-alpine

WORKDIR /app

# Copy root package.json and workspace config
COPY package.json ./
COPY packages ./packages
COPY apps/controller ./apps/controller

# Install dependencies (workspace-aware)
RUN npm install --workspace=apps/controller --only=production

# Set working directory to controller app
WORKDIR /app/apps/controller

# Set permissions for node user (already exists in node:20-alpine)
RUN chown -R node:node /app

# Expose port
EXPOSE 8080

# Run as non-root user
USER node

# Start application
CMD ["node", "index.js"]
