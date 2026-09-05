import { createServer, type Server } from "node:http";
import type { Logger } from "../logger.js";
import type { StatusFile } from "./status.js";

/**
 * `/status` and `/healthz`, on `node:http` with no dependency.
 *
 * `/healthz` is what the Docker HEALTHCHECK and any external monitor hit, so its liveness definition is
 * deliberately narrow: the tick loop is running and recent. A CRIT check means the *protocol* needs
 * attention, not that the keeper is broken, so it does not by itself make the process unhealthy — a
 * container restarted every time USDG wobbles would be strictly worse than one that keeps reporting.
 */

export interface StatusServerOptions {
  host: string;
  port: number;
  staleAfterMs: number;
}

export class StatusServer {
  private server: Server | null = null;
  private status: StatusFile | null = null;
  private lastTickAt = 0;
  private startedAt = Date.now();

  constructor(
    private readonly opts: StatusServerOptions,
    private readonly log: Logger,
  ) {}

  update(status: StatusFile): void {
    this.status = status;
    this.lastTickAt = Date.now();
  }

  private healthy(): { ok: boolean; reason: string } {
    if (this.lastTickAt === 0) {
      const warmup = Date.now() - this.startedAt;
      return warmup < this.opts.staleAfterMs
        ? { ok: true, reason: "starting up" }
        : { ok: false, reason: "no tick has completed since start" };
    }
    const age = Date.now() - this.lastTickAt;
    return age <= this.opts.staleAfterMs
      ? { ok: true, reason: `last tick ${Math.round(age / 1000)}s ago` }
      : {
          ok: false,
          reason: `last tick ${Math.round(age / 1000)}s ago, past the ${Math.round(this.opts.staleAfterMs / 1000)}s budget`,
        };
  }

  start(): void {
    if (this.opts.port === 0) {
      this.log.info("status HTTP server disabled (STATUS_PORT=0)");
      return;
    }
    this.server = createServer((req, res) => {
      const url = (req.url ?? "/").split("?")[0];
      if (url === "/healthz") {
        const h = this.healthy();
        res.writeHead(h.ok ? 200 : 503, { "content-type": "application/json" });
        res.end(
          JSON.stringify({
            ok: h.ok,
            reason: h.reason,
            overall: this.status?.overall ?? "unknown",
          }),
        );
        return;
      }
      if (url === "/status") {
        if (!this.status) {
          res.writeHead(503, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: "no tick has completed yet" }));
          return;
        }
        res.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" });
        res.end(JSON.stringify(this.status));
        return;
      }
      res.writeHead(404, { "content-type": "text/plain" });
      res.end("try /status or /healthz\n");
    });
    this.server.listen(this.opts.port, this.opts.host, () => {
      this.log.info({ host: this.opts.host, port: this.opts.port }, "status server listening");
    });
    this.server.on("error", (err) => this.log.error({ err: err.message }, "status server error"));
  }

  async stop(): Promise<void> {
    const s = this.server;
    if (!s) return;
    await new Promise<void>((resolve) => s.close(() => resolve()));
    this.server = null;
  }
}
