import type { Metadata } from "next";
import { Schibsted_Grotesk } from "next/font/google";
import "./globals.css";

const schibsted = Schibsted_Grotesk({
  variable: "--font-schibsted",
  subsets: ["latin"],
  weight: "variable",
  style: ["normal", "italic"],
  display: "swap",
});

export const metadata: Metadata = {
  title: {
    default: "Overwrite — Make your Stock Tokens pay you every week",
    template: "%s — Overwrite",
  },
  description:
    "Overwrite is the yield layer for tokenized stocks on Robinhood Chain. Market makers bid for your upside every week and pay premium in USDG up front. Two auctions a week, including the weekend.",
};

/**
 * Root layout: document shell only. Wallet providers, header and footer live in the route-group
 * layouts, so the marketing page at `/` ships without the wagmi bundle.
 */
export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${schibsted.variable} h-full`}>
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
