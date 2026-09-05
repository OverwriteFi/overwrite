-- "Get in line" store for the landing page (app/src/app/api/waitlist/route.ts).
-- Run once in the Supabase SQL editor. The API writes with the service-role key; there are no anon
-- policies, so the table is invisible to the public REST API.

create table if not exists public.waitlist (
  id          uuid primary key default gen_random_uuid(),
  contact     text not null unique,                         -- lower-cased email or checksummed 0x address
  kind        text not null check (kind in ('email', 'wallet')),
  source      text,                                          -- 'landing'
  created_at  timestamptz not null default now()
);

alter table public.waitlist enable row level security;
-- No policies on purpose: only the service role (which bypasses RLS) can read or write.

-- Export: select contact, kind, created_at from public.waitlist order by created_at;
