import type { Metadata } from "next";
import { Schibsted_Grotesk } from "next/font/google";
import { headers } from "next/headers";
import { cookieToInitialState } from "wagmi";
import { getConfig } from "@/lib/wagmi";
import { Providers } from "./providers";
import { Header } from "@/components/site/Header";
import { Footer } from "@/components/site/Footer";
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

export default async function RootLayout({ children }: LayoutProps<"/">) {
  const initialState = cookieToInitialState(getConfig(), (await headers()).get("cookie"));
  return (
    <html lang="en" className={`${schibsted.variable} h-full`}>
      <body className="min-h-full flex flex-col">
        <Providers initialState={initialState}>
          <Header />
          <main className="flex-1">{children}</main>
          <Footer />
        </Providers>
      </body>
    </html>
  );
}
