import { NextResponse } from "next/server";
import { appendFile, mkdir } from "node:fs/promises";
import path from "node:path";
import { z } from "zod";
import { classifyContact } from "@/lib/waitlist";

/**
 * "Get in line" store. Supabase table `waitlist` (see app/supabase/waitlist.sql) through PostgREST with
 * the service-role key, server-side only. With no `SUPABASE_URL` set (local dev, previews) rows go to
 * `app/.data/waitlist.jsonl` instead, so the form works without keys. Documented in app/README.md, D-111.
 */

const Body = z.object({ contact: z.string().min(1).max(254), hp: z.string().max(0).optional() });

let warned = false;

async function saveToSupabase(row: Record<string, string>): Promise<boolean> {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return false;
  const res = await fetch(`${url.replace(/\/$/, "")}/rest/v1/waitlist`, {
    method: "POST",
    headers: {
      apikey: key,
      authorization: `Bearer ${key}`,
      "content-type": "application/json",
      // Duplicate contact → no error, no second row.
      prefer: "resolution=ignore-duplicates,return=minimal",
    },
    body: JSON.stringify(row),
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`supabase ${res.status}`);
  return true;
}

async function saveToFile(row: Record<string, string>) {
  const dir = path.join(process.cwd(), ".data");
  await mkdir(dir, { recursive: true });
  await appendFile(path.join(dir, "waitlist.jsonl"), JSON.stringify(row) + "\n", "utf8");
  if (!warned) {
    warned = true;
    console.warn("[waitlist] SUPABASE_URL not set; writing to .data/waitlist.jsonl");
  }
}

export async function POST(req: Request) {
  const json = await req.json().catch(() => null);
  const parsed = Body.safeParse(json);
  if (!parsed.success) return NextResponse.json({ ok: false, error: "Enter an email address or a 0x wallet address." }, { status: 400 });
  const c = classifyContact(parsed.data.contact);
  if (!c) return NextResponse.json({ ok: false, error: "Enter an email address or a 0x wallet address." }, { status: 400 });

  const row = { contact: c.normalised, kind: c.kind, source: "landing", created_at: new Date().toISOString() };
  try {
    if (!(await saveToSupabase(row))) await saveToFile(row);
  } catch (e) {
    console.error("[waitlist]", e instanceof Error ? e.message : e);
    return NextResponse.json({ ok: false, error: "Could not save. Try again." }, { status: 502 });
  }
  return NextResponse.json({ ok: true }, { headers: { "cache-control": "no-store" } });
}
