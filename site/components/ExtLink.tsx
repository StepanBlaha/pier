import { ArrowUpRight } from "lucide-react";
import type { ReactNode } from "react";
import styles from "./ExtLink.module.css";

/** Inline external link: opens in a new tab, with an arrow and a screen reader hint. */
export default function ExtLink({ href, children, className }: { href: string; children: ReactNode; className?: string }) {
  return (
    <a className={`${styles.link} ${className ?? ""}`} href={href} target="_blank" rel="noopener noreferrer">
      {children}
      <ArrowUpRight size={15} aria-hidden="true" />
      <span className="sr-only"> (opens in a new tab)</span>
    </a>
  );
}
