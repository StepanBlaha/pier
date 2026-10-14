import type { MetadataRoute } from "next";
import { BASE_PATH } from "@/lib/site";

export const dynamic = "force-static";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "pier",
    short_name: "pier",
    description: "See what's running on localhost and which project it belongs to.",
    start_url: `${BASE_PATH}/`,
    display: "browser",
    background_color: "#fbf8ee",
    theme_color: "#fbf8ee",
    icons: [{ src: `${BASE_PATH}/icon.png`, sizes: "512x512", type: "image/png" }],
  };
}
