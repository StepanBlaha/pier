"use client";

import { useSyncExternalStore } from "react";
import { AUTHOR } from "@/lib/site";

const subscribe = () => () => {};
const clientYear = () => String(new Date().getFullYear());
// Static server value: the prerendered HTML never calls new Date(); the browser swaps in the real year.
const serverYear = () => "2026";

export default function Copyright() {
  const year = useSyncExternalStore(subscribe, clientYear, serverYear);
  return <span>© {year} {AUTHOR.name}</span>;
}
