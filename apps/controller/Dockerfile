FROM node:20-alpine

WORKDIR /app

# Copy package files
COPY package.json ./

# Install dependencies
RUN npm install --only=production

# Copy application code
COPY . .

# Set permissions for node user (already exists in node:20-alpine)
RUN chown -R node:node /app

# Expose port
EXPOSE 8080

# Run as non-root user
USER node

# Start application
CMD ["node", "index.js"]
