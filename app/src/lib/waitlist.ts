import { getAddress, isAddress } from "viem";

/** Shared by the form and the API route: what counts as a contact, and its canonical form. */
export type Contact = { kind: "email" | "wallet"; normalised: string };

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

export function classifyContact(raw: string): Contact | null {
  const v = raw.trim();
  if (!v || v.length > 254) return null;
  if (isAddress(v)) return { kind: "wallet", normalised: getAddress(v) };
  if (EMAIL.test(v)) return { kind: "email", normalised: v.toLowerCase() };
  return null;
}
