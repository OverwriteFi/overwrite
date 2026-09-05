import {
  BaseError,
  ContractFunctionRevertedError,
  decodeErrorResult,
  hexToString,
  type Abi,
  type Hex,
} from "viem";
import {
  auctionHouseAbi,
  bondManagerAbi,
  capControllerAbi,
  feeRouterAbi,
  optionTokenAbi,
  riskModuleAbi,
  settlementOracleAbi,
  vaultAbi,
} from "../abi/index.js";

/**
 * Turning a revert into something an operator can act on.
 *
 * The protocol speaks two dialects. Custom errors (`CannotOpen(bytes32)`, `NoOraclePath(bytes32,bytes32)`)
 * carry a `bytes32` reason code, and the view mirrors (`canOpen`, `previewSettle`, `canHalt`) return the
 * same codes without reverting. Both end up as the short ASCII strings catalogued in SPEC §9 —
 * "OPEN_WINDOW", "OBSERVATIONS", "JUMP_GUARD" — so the alert layer only has to know one vocabulary.
 */

const ALL_ABIS: Abi[] = [
  auctionHouseAbi,
  vaultAbi,
  settlementOracleAbi,
  riskModuleAbi,
  feeRouterAbi,
  bondManagerAbi,
  optionTokenAbi,
  capControllerAbi,
];

/** `0x4f50454e5f57494e444f57…` → `"OPEN_WINDOW"`. Returns `""` for the zero word. */
export function reasonToString(reason: string): string {
  if (typeof reason !== "string" || !reason.startsWith("0x")) return String(reason);
  try {
    return hexToString(reason as Hex, { size: 32 }).replace(/\0+$/, "");
  } catch {
    return reason;
  }
}

export interface DecodedRevert {
  /** Solidity error name, `Error` for a string revert, or `unknown`. */
  name: string;
  /** Arguments, with any `bytes32` reason already turned into ASCII. */
  args: unknown[];
  /** One-line rendering for logs and alerts. */
  text: string;
  /** The reason codes present in the arguments, for alert routing. */
  reasons: string[];
}

const looksLikeReasonWord = (v: unknown): v is Hex =>
  typeof v === "string" && /^0x[0-9a-fA-F]{64}$/.test(v);

function humanise(name: string, args: readonly unknown[]): DecodedRevert {
  const reasons: string[] = [];
  const mapped = args.map((a) => {
    if (looksLikeReasonWord(a)) {
      const s = reasonToString(a);
      // A bytes32 that decodes to printable ASCII is a reason code; anything else is real data.
      if (s && /^[\x20-\x7E]*$/.test(s)) {
        reasons.push(s);
        return s;
      }
    }
    return typeof a === "bigint" ? a.toString() : a;
  });
  const rendered = mapped
    .map((a) => (typeof a === "object" && a !== null ? JSON.stringify(a) : String(a)))
    .join(", ");
  return { name, args: mapped, reasons, text: rendered ? `${name}(${rendered})` : name };
}

/** Best-effort decode of raw revert data against every protocol ABI. */
export function decodeRevertData(data: Hex): DecodedRevert | null {
  for (const abi of ALL_ABIS) {
    try {
      const { errorName, args } = decodeErrorResult({ abi, data });
      return humanise(errorName, args ?? []);
    } catch {
      /* not this ABI */
    }
  }
  return null;
}

/** Decode whatever viem threw. Always returns something printable. */
export function describeError(err: unknown): DecodedRevert {
  if (err instanceof BaseError) {
    const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      if (reverted.data) {
        return humanise(reverted.data.errorName, reverted.data.args ?? []);
      }
      if (reverted.reason) {
        return {
          name: "Error",
          args: [reverted.reason],
          reasons: [],
          text: `Error(${reverted.reason})`,
        };
      }
    }
    const raw = (err as BaseError & { data?: Hex }).data;
    if (raw && raw !== "0x") {
      const decoded = decodeRevertData(raw);
      if (decoded) return decoded;
    }
    return { name: err.name, args: [], reasons: [], text: err.shortMessage || err.message };
  }
  const message = err instanceof Error ? err.message : String(err);
  return { name: "Error", args: [], reasons: [], text: message };
}

/**
 * Whether a failure is worth retrying with the identical request. Transport hiccups and nonce races are;
 * a revert never is — the inputs have to change first, which is what `maxRederive` is for.
 */
export function isRetryable(err: unknown): boolean {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof ContractFunctionRevertedError)) return false;
    const name = err.name;
    if (
      name === "HttpRequestError" ||
      name === "TimeoutError" ||
      name === "RpcRequestError" ||
      name === "InternalRpcError" ||
      name === "LimitExceededRpcError" ||
      name === "NonceTooLowError" ||
      name === "NonceTooHighError" ||
      name === "ReplacementTransactionUnderpricedError" ||
      name === "TransactionNotFoundError" ||
      name === "WaitForTransactionReceiptTimeoutError"
    ) {
      return true;
    }
  }
  const msg = (err instanceof Error ? err.message : String(err)).toLowerCase();
  return (
    msg.includes("timeout") ||
    msg.includes("socket") ||
    msg.includes("econnreset") ||
    msg.includes("econnrefused") ||
    msg.includes("fetch failed") ||
    msg.includes("nonce too low") ||
    msg.includes("replacement transaction underpriced") ||
    msg.includes("already known")
  );
}
