FROM node:20-alpine AS build
WORKDIR /app

# Copy root package.json and workspace config
COPY package.json ./
COPY package-lock.json* ./
COPY packages ./packages
COPY apps/panel ./apps/panel

# Install all workspace dependencies at root (resolves workspace:*)
RUN npm ci

# Build panel app
WORKDIR /app/apps/panel
RUN npm run build

FROM node:20-alpine
WORKDIR /app

# Copy root package.json and workspace config
COPY package.json ./
COPY package-lock.json* ./
COPY packages ./packages
COPY apps/panel ./apps/panel

# Install all workspace dependencies at root (resolves workspace:*)
RUN npm ci

# Prune to production dependencies only for panel workspace
RUN npm prune --omit=dev --workspace=apps/panel

ENV NODE_ENV=production

# Set working directory to panel app
WORKDIR /app/apps/panel

EXPOSE 3000
CMD ["npm", "run", "start"]
