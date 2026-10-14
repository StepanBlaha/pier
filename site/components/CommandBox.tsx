"use client";

import { useRef } from "react";
import CopyButton from "./CopyButton";
import styles from "./CommandBox.module.css";

type Props = {
  command: string;
  prompt?: string;
  /** Background of the box. Defaults to white; use "cream" on white cards. */
  tone?: "white" | "cream";
  className?: string;
};

/** A shell command with a prompt glyph and a copy button. */
export default function CommandBox({ command, prompt = "$", tone = "white", className }: Props) {
  const ref = useRef<HTMLElement | null>(null);
  return (
    <div className={`${styles.box} ${tone === "cream" ? styles.cream : ""} ${className ?? ""}`}>
      <span className={styles.prompt} aria-hidden="true">{prompt}</span>
      <code ref={ref} className={styles.code}>{command}</code>
      <CopyButton text={command} targetRef={ref} />
    </div>
  );
}
