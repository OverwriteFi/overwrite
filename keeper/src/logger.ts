import pino from "pino";

/**
 * CLAUDE.md rule 1: never write, log or print private keys, mnemonics, or RPC URLs carrying keys.
 *
 * Two layers. `redact.paths` catches the structured fields we know the names of; the `censorSecrets`
 * hook is the backstop for anything that reaches a message string — a viem error that quotes its
 * transport URL, say, which is the realistic way an RPC credential escapes.
 */

const REDACT_PATHS = [
  "privateKey",
  "*.privateKey",
  "*.*.privateKey",
  "key",
  "*.key",
  "mnemonic",
  "*.mnemonic",
  "KEEPER_PRIVATE_KEY",
  "*.KEEPER_PRIVATE_KEY",
  "GUARDIAN_PRIVATE_KEY",
  "*.GUARDIAN_PRIVATE_KEY",
  "authorization",
  "*.authorization",
  "rpcUrl",
  "*.rpcUrl",
  "*.*.rpcUrl",
];

/** 0x + 64 hex, anywhere in a string. */
const HEX_KEY = /\b0x[0-9a-fA-F]{64}\b/g;
/** A URL with userinfo, or one whose path looks like an API key segment. */
const URL_CREDENTIAL = /(https?:\/\/)[^\s/@]+:[^\s/@]+@/g;

export function censorSecrets(input: string): string {
  return input.replace(HEX_KEY, "[redacted-32byte]").replace(URL_CREDENTIAL, "$1[redacted]@");
}

export function createLogger(level: string) {
  return pino({
    level,
    redact: { paths: REDACT_PATHS, censor: "[redacted]" },
    hooks: {
      logMethod(args, method) {
        const scrubbed = args.map((a) => (typeof a === "string" ? censorSecrets(a) : a));
        method.apply(this, scrubbed as typeof args);
      },
    },
    // bigint is everywhere in this codebase and JSON.stringify throws on it
    serializers: {
      err: pino.stdSerializers.err,
    },
    formatters: {
      log(obj) {
        return deepStringifyBigints(obj) as Record<string, unknown>;
      },
    },
    ...(process.env.NODE_ENV !== "production"
      ? {
          transport: {
            target: "pino-pretty",
            options: { colorize: true, translateTime: "HH:MM:ss.l" },
          },
        }
      : {}),
  });
}

function deepStringifyBigints(value: unknown, depth = 0): unknown {
  if (depth > 8) return value;
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map((v) => deepStringifyBigints(v, depth + 1));
  if (value && typeof value === "object" && !(value instanceof Error)) {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) out[k] = deepStringifyBigints(v, depth + 1);
    return out;
  }
  return value;
}

export type Logger = ReturnType<typeof createLogger>;
