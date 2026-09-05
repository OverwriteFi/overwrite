# syntax=docker/dockerfile:1
#
# The keeper image.
#
# Build from the *repo root* so the deploy's address book is inside the context:
#   docker build -f keeper/Dockerfile -t overwrite/keeper:latest .
# or just `docker compose up -d --build` from keeper/, which sets the context for you.
#
# Two things are load-bearing and easy to get wrong.
#
#  - **Timezone data.** The whole schedule rests on `Intl.DateTimeFormat('America/New_York')` resolving
#    the US DST offset: 16:00 ET is 20:00 UTC in summer and 21:00 UTC in winter, and the contract only
#    accepts an expiry inside [Fri 19:30, Fri 21:30] UTC. A runtime built with small-icu silently
#    reports UTC for every zone, so every expiry would be an hour early and every `openAuction` would
#    revert `EXPIRY`. The build asserts both offsets below, and src/startup.ts asserts them again at
#    boot — a wrong image fails immediately and loudly instead of once a week, quietly.
#  - **Non-root with one writable directory.** The run ledger, the volatility audit trail and
#    status.json live under /app/state, which is a volume. Everything else can be read-only.

FROM node:22-alpine AS build
WORKDIR /app
COPY keeper/package.json keeper/package-lock.json ./
RUN npm ci
COPY keeper/tsconfig.json ./
COPY keeper/src ./src
RUN npx tsc -p tsconfig.json

FROM node:22-alpine AS deps
WORKDIR /app
COPY keeper/package.json keeper/package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine AS runtime
RUN apk add --no-cache tzdata

# Fail the build, not the first Monday, if this image cannot do New York.
RUN node -e "const o=t=>{const p=new Intl.DateTimeFormat('en-US',{timeZone:'America/New_York',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(new Date(t*1000)),g=k=>Number(p.find(x=>x.type===k).value);return Date.UTC(g('year'),g('month')-1,g('day'),g('hour'),g('minute'),g('second'))/1000-t};if(o(1789156800)!==-14400||o(1793998800)!==-18000){console.error('ICU/tzdata missing: America/New_York resolves to',o(1789156800),o(1793998800));process.exit(1)}console.log('tzdata ok: EDT -14400, EST -18000')"

ENV NODE_ENV=production \
    TZ=UTC

WORKDIR /app
COPY --from=deps  /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY keeper/package.json ./
COPY keeper/config ./config
# The deploy's address book. Also bind-mounted read-only by compose, so a contracts re-deploy does not
# need an image rebuild; copied here too so the image runs standalone.
COPY contracts/deployments ./deployments

RUN mkdir -p /app/state && chown -R node:node /app/state
USER node
VOLUME ["/app/state"]

ENV STATE_DIR=/app/state \
    STATUS_HOST=0.0.0.0 \
    STATUS_PORT=8787 \
    DEPLOYMENT_DIR=/app/deployments
EXPOSE 8787

# `/healthz` is 200 while the tick loop is running and recent. It deliberately does NOT go red on a
# CRIT check: a CRIT means the protocol needs a human, not that the container should be restarted, and
# a keeper that restarts every time USDG wobbles is worse than one that keeps reporting.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.STATUS_PORT||8787)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "dist/index.js"]
