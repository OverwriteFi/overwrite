import assert from "node:assert/strict";
import { sep } from "node:path";
import { describe, it } from "node:test";
import { deploymentPathFor, loadEnv } from "../src/config.js";

/**
 * The environment parser against the shapes a real `.env` actually has.
 *
 * These are not hypotheticals: the repo's own `.env.example` ships
 * `ROBINHOOD_TESTNET_RPC_URL=rpc.testnet.chain.robinhood.com` with no scheme, and every unused field as
 * a bare `VAR=`. Both used to be fatal — zod reads "" as present-but-invalid rather than absent, and
 * `.url()` rejects a scheme-less host — so the keeper refused to start on the file the RUNBOOK tells
 * you to copy.
 */

// Constructed rather than written out: the pre-commit hook rejects any literal 0x + 64 hex, and it is
// right to, since it cannot tell a test fixture from a real key.
const KEY = `0x${"11".repeat(32)}`;
const OTHER_KEY = `0x${"22".repeat(32)}`;

const base = { CHAIN_ID: "46630", KEEPER_PRIVATE_KEY: KEY };

describe("environment", () => {
  it("accepts the shipped .env shape: blank placeholders and a scheme-less host", () => {
    const env = loadEnv({
      ...base,
      ROBINHOOD_RPC_URL: "",
      ROBINHOOD_TESTNET_RPC_URL: "rpc.testnet.chain.robinhood.com",
      KEEPER_RPC_URL: "",
      GUARDIAN_PRIVATE_KEY: "",
      GUARDIAN_AUTOPAUSE: "",
      EXPLORER_API_KEY: "",
      TELEGRAM_BOT_TOKEN: "",
      TELEGRAM_CHAT_ID: "",
      STATUS_FILE: "",
      LOG_LEVEL: "",
      STATUS_PORT: "",
    });

    assert.equal(env.ROBINHOOD_TESTNET_RPC_URL, "https://rpc.testnet.chain.robinhood.com");
    assert.equal(env.ROBINHOOD_RPC_URL, undefined);
    assert.equal(env.GUARDIAN_PRIVATE_KEY, undefined);
    assert.equal(env.GUARDIAN_AUTOPAUSE, false);
    assert.equal(
      env.TELEGRAM_BOT_TOKEN,
      undefined,
      "an unset token must disable alerting, not crash",
    );
    assert.equal(env.LOG_LEVEL, "info", "a blank value falls back to the default");
    assert.equal(env.STATUS_PORT, 8787);
  });

  it("leaves an explicit scheme alone and trims whitespace", () => {
    const env = loadEnv({
      ...base,
      ROBINHOOD_TESTNET_RPC_URL: "  http://127.0.0.1:8545  ",
    });
    assert.equal(env.ROBINHOOD_TESTNET_RPC_URL, "http://127.0.0.1:8545");
  });

  it("still rejects a missing or malformed keeper key, without echoing it", () => {
    assert.throws(
      () => loadEnv({ CHAIN_ID: "46630" }),
      (e: Error) => e.message.includes("KEEPER_PRIVATE_KEY"),
    );
    assert.throws(
      () => loadEnv({ ...base, KEEPER_PRIVATE_KEY: "0xdeadbeef" }),
      (e: Error) => e.message.includes("64 hex") && !e.message.includes("deadbeef"),
    );
  });

  it("rejects an unsupported chain id", () => {
    assert.throws(() => loadEnv({ ...base, CHAIN_ID: "1" }));
    assert.throws(() => loadEnv({ ...base, CHAIN_ID: "" }));
  });

  it("requires a guardian key only when auto-pause is armed", () => {
    assert.equal(loadEnv({ ...base, GUARDIAN_AUTOPAUSE: "false" }).GUARDIAN_AUTOPAUSE, false);
    assert.throws(
      () => loadEnv({ ...base, GUARDIAN_AUTOPAUSE: "true" }),
      /requires GUARDIAN_PRIVATE_KEY/,
    );
    const armed = loadEnv({
      ...base,
      GUARDIAN_AUTOPAUSE: "true",
      GUARDIAN_PRIVATE_KEY: OTHER_KEY,
    });
    assert.equal(armed.GUARDIAN_AUTOPAUSE, true);
  });

  it("reads the boolean spellings a .env realistically contains", () => {
    for (const yes of ["true", "1", "yes"]) {
      assert.equal(loadEnv({ ...base, DRY_RUN: yes }).DRY_RUN, true, yes);
    }
    for (const no of ["false", "0", "no", ""]) {
      assert.equal(loadEnv({ ...base, DRY_RUN: no }).DRY_RUN, false, no || "(blank)");
    }
  });
});

describe("address book resolution", () => {
  const file = { deploymentPath: "../contracts/deployments/46630.json" } as Parameters<
    typeof deploymentPathFor
  >[1];

  it("prefers an explicit path, then a directory, then the config's own", () => {
    const env = (extra: Record<string, string>) => loadEnv({ ...base, ...extra });

    assert.equal(
      deploymentPathFor(env({ DEPLOYMENT_PATH: "/somewhere/46630.json" }), file),
      "/somewhere/46630.json",
    );
    // The container image sets DEPLOYMENT_DIR so it runs standalone: the checked-in config points at
    // ../contracts/deployments, which resolves outside the image from /app.
    assert.equal(
      deploymentPathFor(env({ DEPLOYMENT_DIR: "/app/deployments" }), file)
        .split(sep)
        .join("/"),
      "/app/deployments/46630.json",
    );
    assert.equal(deploymentPathFor(env({}), file), "../contracts/deployments/46630.json");
  });
});
