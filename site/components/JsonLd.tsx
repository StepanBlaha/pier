import { AUTHOR, REPO_URL, SITE_URL, VERSION } from "@/lib/site";

/** Structured data with real facts only (no ratings, no download counts). */
export default function JsonLd() {
  const data = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "pier",
    description: "A macOS menu bar app and CLI that shows what's running on localhost and which project it belongs to.",
    applicationCategory: "DeveloperApplication",
    operatingSystem: "macOS 14 or later",
    softwareVersion: VERSION,
    license: "https://opensource.org/licenses/MIT",
    url: SITE_URL,
    downloadUrl: `${REPO_URL}/releases/latest`,
    codeRepository: REPO_URL,
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    author: { "@type": "Person", name: AUTHOR.name, url: AUTHOR.url, sameAs: [AUTHOR.github] },
  };
  return <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(data) }} />;
}
