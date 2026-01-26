FROM node:20-alpine AS build
WORKDIR /app
COPY package.json tsconfig.json next.config.mjs ./
COPY next-env.d.ts ./next-env.d.ts
COPY postcss.config.js tailwind.config.js ./
COPY app ./app
COPY mock-data ./mock-data
COPY src ./src
RUN npm install
RUN npm run build

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=build /app/package.json /app/package.json
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/.next /app/.next
COPY --from=build /app/app /app/app
COPY --from=build /app/mock-data /app/mock-data
COPY --from=build /app/src /app/src
EXPOSE 3000
CMD ["npm", "run", "start"]
