FROM node:20-alpine AS build
WORKDIR /app

# Copy root package.json and workspace config
COPY package.json ./
COPY packages ./packages
COPY apps/panel ./apps/panel

# Install dependencies (workspace-aware)
RUN npm install --workspace=apps/panel

# Build panel app
WORKDIR /app/apps/panel
RUN npm run build

FROM node:20-alpine
WORKDIR /app

# Copy root package.json and workspace config
COPY package.json ./
COPY packages ./packages
COPY apps/panel ./apps/panel

# Install production dependencies only (workspace-aware)
RUN npm install --workspace=apps/panel --only=production

ENV NODE_ENV=production

# Set working directory to panel app
WORKDIR /app/apps/panel

EXPOSE 3000
CMD ["npm", "run", "start"]
