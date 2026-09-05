"use client";

import { useState, type FormEvent } from "react";
import { classifyContact } from "@/lib/waitlist";

type Phase = "idle" | "sending" | "done" | "error";

/** "Get in line": one field, one button, one message promised. Posts to /api/waitlist. */
export function GetInLine() {
  const [contact, setContact] = useState("");
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState("");

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const c = classifyContact(contact);
    if (!c) {
      setPhase("error");
      setError("Enter an email address or a 0x wallet address.");
      return;
    }
    setPhase("sending");
    setError(null);
    try {
      const hp = (e.currentTarget.elements.namedItem("company") as HTMLInputElement | null)?.value ?? "";
      const res = await fetch("/api/waitlist", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ contact: c.normalised, hp }),
      });
      const body = (await res.json().catch(() => ({}))) as { ok?: boolean; error?: string };
      if (!res.ok || !body.ok) throw new Error(body.error ?? "Could not save. Try again.");
      setSaved(c.normalised);
      setPhase("done");
    } catch (err) {
      setPhase("error");
      setError(err instanceof Error ? err.message : "Could not save. Try again.");
    }
  }

  if (phase === "done") {
    return (
      <p className="joined" role="status">
        You&apos;re in line. One message will go to <b>{saved}</b>: the first auction&apos;s clearing premium, the moment
        it clears. Nothing else.
      </p>
    );
  }

  return (
    <form className="join" onSubmit={submit} noValidate>
      <label htmlFor="contact" className="sr-only">
        Email or wallet address
      </label>
      <input
        id="contact"
        name="contact"
        type="text"
        autoComplete="email"
        placeholder="Email or wallet address"
        value={contact}
        onChange={(e) => setContact(e.target.value)}
        aria-invalid={phase === "error" ? true : undefined}
        aria-describedby={error ? "join-err" : undefined}
      />
      <input name="company" type="text" tabIndex={-1} autoComplete="off" className="hp" aria-hidden="true" />
      <button type="submit" className="btn btn-blue" disabled={phase === "sending"}>
        {phase === "sending" ? "Saving…" : "Get in line"}
      </button>
      {error ? (
        <span id="join-err" className="err" role="alert">
          {error}
        </span>
      ) : null}
    </form>
  );
}
