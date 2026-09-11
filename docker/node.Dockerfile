# Multi-target image for the TypeScript services and the Next.js frontend.
#   target "services" -> indexer, api and monitor (same image, different command)
#   target "frontend" -> Next.js standalone server
# Dependency lifecycle scripts never run (.npmrc ignore-scripts=true).

FROM node:20-alpine AS deps
RUN npm install -g pnpm@9.15.9 --ignore-scripts
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc tsconfig.base.json ./
COPY shared/package.json shared/
COPY indexer/package.json indexer/
COPY backend/package.json backend/
COPY frontend/package.json frontend/
COPY e2e/package.json e2e/
RUN pnpm install --frozen-lockfile

FROM deps AS build-services
COPY shared shared
COPY indexer indexer
COPY backend backend
RUN pnpm --filter @lending/shared build \
 && pnpm --filter @lending/indexer build \
 && pnpm --filter @lending/backend build

FROM node:20-alpine AS services
ENV NODE_ENV=production
WORKDIR /app
COPY --from=build-services /app /app
USER node
# Overridden per service in docker-compose.yml
CMD ["node", "backend/dist/api.js"]

FROM deps AS build-frontend
# NEXT_PUBLIC_* values are inlined into the browser bundle at build time.
ARG NEXT_PUBLIC_API_URL=http://localhost:4400
ARG NEXT_PUBLIC_RPC_URL=http://localhost:8545
ARG NEXT_PUBLIC_DEV_WALLETS=true
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL \
    NEXT_PUBLIC_RPC_URL=$NEXT_PUBLIC_RPC_URL \
    NEXT_PUBLIC_DEV_WALLETS=$NEXT_PUBLIC_DEV_WALLETS \
    NEXT_TELEMETRY_DISABLED=1
COPY shared shared
COPY frontend frontend
RUN pnpm --filter @lending/shared build && pnpm --filter @lending/frontend build

FROM node:20-alpine AS frontend
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3400 HOSTNAME=0.0.0.0
WORKDIR /app
COPY --from=build-frontend /app/frontend/.next/standalone ./
COPY --from=build-frontend /app/frontend/.next/static ./frontend/.next/static
USER node
EXPOSE 3400
CMD ["node", "frontend/server.js"]
