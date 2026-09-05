import type { Logger } from "../logger.js";
import type { Check, Severity } from "./checks.js";

/**
 * Telegram alerting.
 *
 * Plain `fetch`, no dependency. Three properties that matter more than the transport:
 *
 *  - **Dedupe with a cooldown.** A check that is failing is failing every 30 seconds. Without dedupe the
 *    channel becomes unreadable within an hour and stops being read at all.
 *  - **Explicit recovery messages.** An alert nobody clears is an alert nobody trusts.
 *  - **Silence when unconfigured.** No token means the sender is a no-op with one startup log line, so a
 *    dry run or a fork test does not need credentials and does not accidentally page anyone.
 */

const RANK: Record<Severity, number> = { na: -1, ok: 0, info: 1, warn: 2, crit: 3 };

export interface AlertState {
  firedAt: number;
  severity: Severity;
  summary: string;
}

export class Alerter {
  private readonly open = new Map<string, AlertState>();

  constructor(
    private readonly opts: {
      botToken?: string | undefined;
      chatId?: string | undefined;
      minSeverity: Severity;
      cooldownSeconds: number;
      label: string;
      dryRun: boolean;
    },
    private readonly log: Logger,
  ) {}

  get enabled(): boolean {
    return Boolean(this.opts.botToken && this.opts.chatId);
  }

  private key(c: Check): string {
    return c.vault ? `${c.id}:${c.vault}` : c.id;
  }

  /** Diffs this tick's checks against what is already open and sends only the changes. */
  async reconcile(checks: readonly Check[]): Promise<void> {
    const now = Date.now();
    const seen = new Set<string>();

    for (const c of checks) {
      const k = this.key(c);
      seen.add(k);
      const failing = RANK[c.severity] >= RANK[this.opts.minSeverity];
      const prior = this.open.get(k);

      if (!failing) {
        if (prior) {
          this.open.delete(k);
          await this.send(`✅ RECOVERED · ${k}\n${c.summary}`);
        }
        continue;
      }

      const escalated = prior && RANK[c.severity] > RANK[prior.severity];
      const cooled = prior && now - prior.firedAt >= this.opts.cooldownSeconds * 1000;
      if (prior && !escalated && !cooled) continue;

      this.open.set(k, { firedAt: now, severity: c.severity, summary: c.summary });
      const icon = c.severity === "crit" ? "🔴" : c.severity === "warn" ? "🟠" : "🔵";
      const parts = [`${icon} ${c.severity.toUpperCase()} · ${k}`, c.summary];
      if (c.measured) parts.push(`measured: ${c.measured}`);
      if (c.threshold) parts.push(`threshold: ${c.threshold}`);
      await this.send(parts.join("\n"));
    }

    // A check that stopped being reported (a vault removed from config, say) is cleared too.
    for (const k of [...this.open.keys()]) {
      if (!seen.has(k)) this.open.delete(k);
    }
  }

  async notify(text: string): Promise<void> {
    await this.send(text);
  }

  private async send(text: string): Promise<void> {
    const body = `[${this.opts.label}${this.opts.dryRun ? " · DRY RUN" : ""}] ${text}`;
    this.log.info({ alert: body.split("\n")[0] }, "alert");
    if (!this.enabled) return;
    try {
      const res = await fetch(`https://api.telegram.org/bot${this.opts.botToken}/sendMessage`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          chat_id: this.opts.chatId,
          text: body,
          disable_web_page_preview: true,
        }),
        signal: AbortSignal.timeout(10_000),
      });
      if (!res.ok) {
        // Never log the response body: a Telegram error can echo the request URL, which carries the token.
        this.log.warn({ status: res.status }, "telegram rejected an alert");
      }
    } catch (err) {
      this.log.warn({ err: (err as Error).name }, "telegram send failed");
    }
  }

  get openAlerts(): { key: string; severity: Severity; summary: string }[] {
    return [...this.open.entries()].map(([key, v]) => ({
      key,
      severity: v.severity,
      summary: v.summary,
    }));
  }
}
