FROM node:20-alpine AS build
WORKDIR /app

# Copy root package.json and workspace config
COPY package.json ./
COPY package-lock.json* ./
COPY packages ./packages
COPY apps/panel ./apps/panel

# Install all workspace dependencies at root (resolves workspace:*)
RUN npm ci --workspaces

# Build panel app
WORKDIR /app/apps/panel
RUN npm run build

FROM node:20-alpine
WORKDIR /app

# Copy root package.json and workspace config
COPY package.json ./
COPY package-lock.json* ./
COPY packages ./packages

# Copy panel app source code and config files (excluding node_modules)
COPY --from=build /app/apps/panel/package.json ./apps/panel/
COPY --from=build /app/apps/panel/package-lock.json* ./apps/panel/
COPY --from=build /app/apps/panel/next.config.mjs ./apps/panel/
COPY --from=build /app/apps/panel/tsconfig.json ./apps/panel/
COPY --from=build /app/apps/panel/postcss.config.js ./apps/panel/
COPY --from=build /app/apps/panel/tailwind.config.js ./apps/panel/
COPY --from=build /app/apps/panel/next-env.d.ts ./apps/panel/
COPY --from=build /app/apps/panel/app ./apps/panel/app
COPY --from=build /app/apps/panel/src ./apps/panel/src
COPY --from=build /app/apps/panel/.next ./apps/panel/.next

# Install all workspace dependencies at root (resolves workspace:*)
RUN npm ci --workspaces --omit=dev

ENV NODE_ENV=production

# Set working directory to panel app
WORKDIR /app/apps/panel

EXPOSE 3000
CMD ["npm", "run", "start"]
