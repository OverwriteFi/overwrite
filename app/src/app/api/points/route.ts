import { NextResponse } from "next/server";
import { isAddress } from "viem";
import { pointsFor } from "@/lib/reads/points";

export async function GET(req: Request) {
  const address = new URL(req.url).searchParams.get("address") ?? "";
  if (!isAddress(address)) {
    return NextResponse.json({ error: "address required" }, { status: 400 });
  }
  const data = await pointsFor(address);
  return NextResponse.json(data, { headers: { "cache-control": "no-store" } });
}
