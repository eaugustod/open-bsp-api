# ====================================================================
# OpenBSP Unified Container (API Gateway + Edge Functions + Web UI)
# ====================================================================

# Stage 1: Build the Web UI (React + Tailwind + Vite)
FROM node:20-alpine AS ui-builder
WORKDIR /app/ui

# Install dependencies with npm ci
COPY ui/package*.json ./
RUN npm ci

# Copy UI source
COPY ui/ ./

# Build arguments for Supabase & Meta
ARG VITE_SUPABASE_URL
ARG VITE_SUPABASE_ANON_KEY
ARG VITE_SUPABASE_SCHEMA=openbsp
ARG VITE_META_APP_ID
ARG VITE_FB_LOGIN_CONFIG_ID

ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL \
    VITE_SUPABASE_ANON_KEY=$VITE_SUPABASE_ANON_KEY \
    VITE_SUPABASE_SCHEMA=$VITE_SUPABASE_SCHEMA \
    VITE_META_APP_ID=$VITE_META_APP_ID \
    VITE_FB_LOGIN_CONFIG_ID=$VITE_FB_LOGIN_CONFIG_ID

RUN npm run build

# Stage 2: Lightweight Deno Runtime (<80MB RAM)
FROM denoland/deno:2.1.4

WORKDIR /app

# Copy Deno configuration files
COPY deno.json ./
COPY supabase/functions/deno.json ./supabase/functions/deno.json

# Copy backend functions and server gateway
COPY server.ts ./
COPY supabase/functions ./supabase/functions

# Copy compiled static Web UI
COPY --from=ui-builder /app/ui/dist ./ui/dist

# Pre-cache Deno dependencies for lightning-fast startup
RUN deno cache server.ts

# Default environment configuration
ENV PORT=8080 \
    SUPABASE_DB_SCHEMA=openbsp

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/healthz || exit 1

ENTRYPOINT ["deno"]
CMD ["run", "--allow-net", "--allow-read", "--allow-env", "server.ts"]

