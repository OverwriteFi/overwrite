import type { Address, PublicClient } from "viem";
import { riskModuleAbi } from "../abi/index.js";
import type { Clients } from "../chain/clients.js";
import { buildGuardianAllowTable, createSender, type Sender } from "../chain/tx.js";
import type { ResolvedConfig } from "../config.js";
import type { Logger } from "../logger.js";
import type { Alerter } from "./alerts.js";
import type { Check } from "./checks.js";

/**
 * The D-020 automatic pause.
 *
 * SPEC §9.5 and D-020: the keeper watches the stock-token beacon and the USDG implementation, and on
 * any change pauses deposits and new auctions on every vault with the guardian key, then pages the
 * founder. D-012 as amended by D-029 puts that guardian key on the keeper server precisely so this can
 * happen "within seconds with nobody present".
 *
 * Two constraints hold it in place:
 *
 *  - **A different key.** The keeper's transaction key holds `KEEPER_ROLE` and must never hold
 *    `GUARDIAN_ROLE` — a compromised server that held both would leave nobody able to pause a rogue
 *    keeper during the 48 h it takes the timelock to revoke it. `createClients` refuses to start when
 *    the two keys are equal.
 *  - **Off by default.** `GUARDIAN_AUTOPAUSE=false` ships the path working but disarmed. Pausing every
 *    vault is a real, user-visible action; arming it should be a deliberate decision by whoever runs
 *    the server, not a side effect of installing the keeper.
 *
 * The guardian can only pause and unpause. Its allowlist is separate from the keeper's and contains
 * four functions, none of which can move a token.
 */

export class GuardianModule {
  private readonly sender: Sender | null;
  private tripped = false;

  constructor(
    private readonly cfg: ResolvedConfig,
    clients: Clients,
    private readonly client: PublicClient,
    private readonly log: Logger,
    private readonly alerter: Alerter,
  ) {
    this.sender =
      clients.guardian && clients.guardianWallet
        ? createSender({
            publicClient: client,
            wallet: clients.guardianWallet,
            account: clients.guardian,
            allow: buildGuardianAllowTable(cfg.deployment),
            options: cfg.file.tx,
            dryRun: cfg.env.DRY_RUN,
            log: log.child({ key: "guardian" }),
          })
        : null;
  }

  get armed(): boolean {
    return this.sender !== null;
  }

  describe(): string {
    if (!this.cfg.env.GUARDIAN_AUTOPAUSE)
      return "disarmed (GUARDIAN_AUTOPAUSE=false): implementation changes alert only";
    return this.sender
      ? `armed with guardian key ${this.sender.address}`
      : "armed but no guardian key loaded";
  }

  /**
   * Called with each tick's checks. An `implementation.watch` CRIT is the D-020 trigger; everything else
   * is somebody else's problem.
   */
  async onChecks(checks: readonly Check[]): Promise<void> {
    const trigger = checks.find((c) => c.id === "implementation.watch" && c.severity === "crit");
    if (!trigger || this.tripped) return;
    this.tripped = true;

    await this.alerter.notify(
      `🚨 D-020 TRIGGER\n${trigger.summary}\n` +
        (this.sender
          ? "pausing deposits and new auctions on every vault now"
          : "auto-pause is disarmed — a human must pause with the guardian key and review the new implementation before anything else happens"),
    );

    if (!this.sender) {
      this.log.error(
        { check: trigger.summary },
        "implementation changed and auto-pause is disarmed",
      );
      return;
    }

    // `ALL = address(0)` dominates the per-vault flags (D-050), so this is two calls, not 2n.
    const ALL = "0x0000000000000000000000000000000000000000" as Address;
    for (const fn of ["pauseDeposits", "pauseNewAuctions"] as const) {
      const r = await this.sender.send({
        address: this.cfg.deployment.core.riskModule,
        abi: riskModuleAbi,
        functionName: fn,
        args: [ALL],
        label: `guardian ${fn}(ALL)`,
      });
      this.log.error({ fn, status: r.status }, "guardian pause");
    }
    await this.alerter.notify(
      "paused. Unpause only after a human has confirmed the new implementation keeps raw-unit balanceOf, " +
        "no transfer fee, no transfer hooks and unchanged decimals (D-020).",
    );
  }
}
