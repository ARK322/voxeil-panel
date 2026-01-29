FROM node:20-alpine

WORKDIR /app

# Copy root package.json and workspace config
COPY package.json ./
COPY package-lock.json* ./
COPY packages ./packages
COPY apps/controller ./apps/controller

# Install all workspace dependencies at root (resolves workspace:*)
RUN npm ci --workspaces

# Prune to production dependencies only for controller workspace
RUN npm prune --omit=dev --workspace=apps/controller

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
