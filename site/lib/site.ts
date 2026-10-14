/** Single source for facts shown on the site. Keep in sync with the pier repo. */
export const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://stepanblaha.github.io/pier";
export const BASE_PATH = process.env.NEXT_PUBLIC_BASE_PATH ?? "";
export const REPO_URL = "https://github.com/StepanBlaha/pier";
export const RELEASES_URL = `${REPO_URL}/releases/latest`;
export const VERSION = "0.1.2";
export const BREW_INSTALL = "brew install stepanblaha/tap/pier";
export const APP_INSTALL = "pier app install";
export const MCP_ADD = "claude mcp add --scope user pier -- pier mcp";
export const AUTHOR = { name: "Štěpán Bláha", url: "https://stepanblaha.com", github: "https://github.com/StepanBlaha" };

/** Prefix a path in /public with the basePath (for plain <img>/<a> that Next doesn't rewrite). */
export const asset = (p: string) => `${BASE_PATH}${p.startsWith("/") ? p : `/${p}`}`;
