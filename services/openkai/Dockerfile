FROM node:22-slim AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml* ./
RUN pnpm install --frozen-lockfile || pnpm install
COPY tsconfig.json ./
COPY src/ ./src/
RUN pnpm build

FROM node:22-slim
WORKDIR /app
RUN corepack enable
COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/package.json ./
COPY config/ ./config/
VOLUME /data
EXPOSE 3210
CMD ["node", "dist/index.js"]
