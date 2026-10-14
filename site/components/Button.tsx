import Link from "next/link";
import { ArrowUpRight } from "lucide-react";
import type { MouseEventHandler, ReactNode } from "react";
import styles from "./Button.module.css";

type Props = {
  href: string;
  children: ReactNode;
  /** yellow: beak CTA (hover navy). navy: solid (hover blue). white: outlined (hover navy). */
  variant?: "yellow" | "navy" | "white";
  size?: "md" | "sm";
  /** Opens in a new tab with an arrow icon and screen reader hint. */
  external?: boolean;
  icon?: ReactNode;
  onClick?: MouseEventHandler<HTMLAnchorElement>;
  className?: string;
};

export default function ButtonLink({ href, children, variant = "yellow", size = "md", external, icon, onClick, className }: Props) {
  const cls = [styles.btn, styles[variant], size === "sm" ? styles.sm : "", className ?? ""].filter(Boolean).join(" ");
  const inner = (
    <>
      {icon}
      <span>{children}</span>
      {external && (
        <>
          <ArrowUpRight size={18} aria-hidden="true" />
          <span className="sr-only"> (opens in a new tab)</span>
        </>
      )}
    </>
  );
  if (external) {
    return (
      <a className={cls} href={href} target="_blank" rel="noopener noreferrer" onClick={onClick}>
        {inner}
      </a>
    );
  }
  if (href.startsWith("/")) {
    return (
      <Link className={cls} href={href} onClick={onClick}>
        {inner}
      </Link>
    );
  }
  return (
    <a className={cls} href={href} onClick={onClick}>
      {inner}
    </a>
  );
}
