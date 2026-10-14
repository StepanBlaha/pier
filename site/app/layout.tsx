import type { Metadata, Viewport } from "next";
import { Bricolage_Grotesque, JetBrains_Mono } from "next/font/google";
import ScrollProvider from "@/components/ScrollProvider";
import { AUTHOR, SITE_URL } from "@/lib/site";
import "locomotive-scroll/dist/locomotive-scroll.css";
import "./globals.css";

const display = Bricolage_Grotesque({ subsets: ["latin", "latin-ext"], variable: "--font-display", display: "swap" });
const code = JetBrains_Mono({ subsets: ["latin"], variable: "--font-code", display: "swap", weight: ["400", "600"] });

const description =
  "pier shows what's running on localhost and which project it belongs to. A free, open source macOS menu bar app and CLI to find, open, restart and clean up your dev servers.";

export const metadata: Metadata = {
  // Origin only: Next already prefixes file-based metadata (og image, icons) with the basePath.
  metadataBase: new URL(new URL(SITE_URL).origin),
  title: { default: "pier: who's on port 3000?", template: "%s | pier" },
  description,
  applicationName: "pier",
  authors: [{ name: AUTHOR.name, url: AUTHOR.url }],
  creator: AUTHOR.name,
  keywords: ["localhost", "ports", "dev server", "macOS", "menu bar", "CLI", "lsof", "Next.js", "Vite", "MCP", "Claude Code"],
  alternates: { canonical: `${SITE_URL}/` },
  openGraph: {
    type: "website",
    url: `${SITE_URL}/`,
    siteName: "pier",
    title: "pier: who's on port 3000?",
    description,
  },
  twitter: { card: "summary_large_image", title: "pier: who's on port 3000?", description, creator: "@StepanBlaha" },
};

export const viewport: Viewport = { themeColor: "#fbf8ee", colorScheme: "light" };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className={`${display.variable} ${code.variable}`}>
      <body>
        <a className="skip-link" href="#main">Skip to content</a>
        <ScrollProvider />
        {children}
      </body>
    </html>
  );
}
