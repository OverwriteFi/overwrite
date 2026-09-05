import { NextResponse } from "next/server";
import { targetChainId } from "@/lib/chains";
import { publicClient } from "@/lib/reads/client";

export async function GET() {
  try {
    const block = await publicClient().getBlock({ blockTag: "latest" });
    return NextResponse.json(
      { ok: true, chainId: targetChainId, block: block.number.toString(), timestamp: block.timestamp.toString() },
      { headers: { "cache-control": "no-store" } },
    );
  } catch (e) {
    return NextResponse.json(
      { ok: false, chainId: targetChainId, error: (e as Error).message },
      { status: 503, headers: { "cache-control": "no-store" } },
    );
  }
}
