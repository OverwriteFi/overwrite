"use client";

import { useCallback, useState } from "react";
import {
  BaseError,
  ContractFunctionRevertedError,
  UserRejectedRequestError,
  type Abi,
  type Address,
  type Hash,
  type TransactionReceipt,
} from "viem";
import { useConfig } from "wagmi";
import { getAccount, waitForTransactionReceipt, writeContract } from "wagmi/actions";
import { targetChain } from "@/lib/chains";

export type TxStatus = "idle" | "confirming" | "pending" | "success" | "error";

/** Plain-English messages for the protocol's custom errors. Anything unknown falls back to the name. */
const MESSAGES: Record<string, string> = {
  ERC4626ExceededMaxDeposit: "The vault is at capacity right now. Capacity grows as the backstop grows.",
  ERC4626ExceededMaxWithdraw: "That is more than you can withdraw right now.",
  ERC4626ExceededMaxRedeem: "That is more than you can redeem right now.",
  CapPriceUnavailable: "The price feed is unavailable, so the cap cannot be checked. Try again shortly.",
  CapExceeded: "The vault is at capacity right now. Capacity grows as the backstop grows.",
  VaultNotIdle:
    "A series is live. Deposits execute at the next settlement; queue the deposit instead.",
  WithdrawalsClosed:
    "A series is live. Withdrawals execute at the next settlement; queue the withdrawal instead.",
  VaultIsIdle: "The vault is idle, so you can withdraw directly instead of queueing.",
  DepositsPaused: "Deposits are paused by the guardian.",
  VaultSunsetted: "This vault is sunset and no longer accepts deposits.",
  NothingToClaim: "Nothing to claim yet.",
  NotRequester: "Only the account that queued this request can cancel it.",
  BadRequestStatus: "This request has already been processed or cancelled.",
  CannotTransferToVault: "The receiver cannot be the vault itself.",
  ZeroAmount: "Enter an amount above zero.",
  ZeroShares: "That amount is too small to mint a share.",
  CooldownActive: "Your unstake cooldown is still running.",
  WindowClosed: "The claim window has closed. Request the unstake again.",
  NoCooldown: "There is no unstake request to act on.",
  InsufficientShares: "You do not have that many staked.",
  BelowMinimumResidual: "Leave at least a dust balance staked, or unstake everything.",
};

export function describeError(e: unknown): string {
  if (e instanceof BaseError) {
    const rej = e.walk((x) => x instanceof UserRejectedRequestError);
    if (rej) return "You rejected the transaction in your wallet.";
    const rev = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (rev instanceof ContractFunctionRevertedError) {
      const name = rev.data?.errorName ?? rev.reason;
      if (name && MESSAGES[name]) return MESSAGES[name];
      if (name) return `The contract refused: ${name}.`;
    }
    if (/insufficient funds/i.test(e.shortMessage)) return "Not enough ETH for gas on Robinhood Chain.";
    if (/chain mismatch|does not match the target chain|wrong chain/i.test(e.shortMessage)) {
      return `Your wallet is on another chain. Switch to ${targetChain.name} and try again.`;
    }
    return e.shortMessage;
  }
  if (e instanceof Error) return e.message;
  return "Something went wrong.";
}

export interface WriteArgs {
  address: Address;
  abi: Abi | readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
}

export function useTx() {
  const config = useConfig();
  const [status, setStatus] = useState<TxStatus>("idle");
  const [hash, setHash] = useState<Hash | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [receipt, setReceipt] = useState<TransactionReceipt | null>(null);

  const reset = useCallback(() => {
    setStatus("idle");
    setHash(null);
    setError(null);
    setReceipt(null);
  }, []);

  const send = useCallback(
    async (w: WriteArgs): Promise<TransactionReceipt | null> => {
      setError(null);
      setReceipt(null);
      // Fresh pre-send check straight from the connector, not from a stale render.
      const acct = getAccount(config);
      if (!acct.address) {
        setError("Connect a wallet first.");
        setStatus("error");
        return null;
      }
      if (acct.chainId !== targetChain.id) {
        setError(`Your wallet is on another chain. Switch to ${targetChain.name} and try again.`);
        setStatus("error");
        return null;
      }
      try {
        setStatus("confirming");
        const h = await writeContract(config, {
          address: w.address,
          abi: w.abi as Abi,
          functionName: w.functionName,
          args: w.args as never,
          value: w.value,
          chainId: targetChain.id,
          account: acct.address,
        } as never);
        setHash(h);
        setStatus("pending");
        const r = await waitForTransactionReceipt(config, { hash: h, chainId: targetChain.id });
        setReceipt(r);
        if (r.status === "reverted") {
          setError("The transaction reverted on-chain.");
          setStatus("error");
          return null;
        }
        setStatus("success");
        return r;
      } catch (e) {
        setError(describeError(e));
        setStatus("error");
        return null;
      }
    },
    [config],
  );

  return { send, status, hash, error, receipt, reset, busy: status === "confirming" || status === "pending" };
}
