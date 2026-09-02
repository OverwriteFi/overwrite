import pino from "pino";

export function createLogger(level: string) {
  return pino({
    level,
    redact: { paths: ["*.privateKey", "privateKey"], censor: "[redacted]" },
    ...(process.env.NODE_ENV !== "production"
      ? { transport: { target: "pino-pretty", options: { colorize: true } } }
      : {}),
  });
}

export type Logger = ReturnType<typeof createLogger>;
