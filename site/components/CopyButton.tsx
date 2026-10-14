"use client";

import { useCallback, useEffect, useRef, useState, type RefObject } from "react";
import { Check, Copy } from "lucide-react";
import styles from "./CopyButton.module.css";

type Status = "idle" | "copied" | "selected";

type Props = {
  text: string;
  /** Element holding the text; selected as a fallback when the Clipboard API is unavailable. */
  targetRef?: RefObject<HTMLElement | null>;
  /** Icon first, compact chrome (for grids and chat bubbles). */
  compact?: boolean;
  className?: string;
};

function selectNode(node: HTMLElement | null | undefined) {
  if (!node) return false;
  const sel = window.getSelection();
  if (!sel) return false;
  const range = document.createRange();
  range.selectNodeContents(node);
  sel.removeAllRanges();
  sel.addRange(range);
  return true;
}

export default function CopyButton({ text, targetRef, compact = false, className }: Props) {
  const [status, setStatus] = useState<Status>("idle");
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  const flash = useCallback((next: Status) => {
    setStatus(next);
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => setStatus("idle"), next === "copied" ? 1500 : 3000);
  }, []);

  const onClick = useCallback(async () => {
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text);
        flash("copied");
        return;
      }
    } catch {
      /* fall through to the manual path */
    }
    // Fallback: select the text so the reader can press Cmd+C, and try the legacy command first.
    const selected = selectNode(targetRef?.current);
    let ok = false;
    try { ok = selected && document.execCommand("copy"); } catch { ok = false; }
    flash(ok ? "copied" : "selected");
  }, [text, targetRef, flash]);

  const done = status !== "idle";
  const label = status === "selected" ? "Selected" : status === "copied" ? "Copied" : "Copy";
  const announce = status === "copied" ? "Copied to clipboard" : status === "selected" ? "Text selected. Press Command C to copy." : "";

  return (
    <>
      <button
        type="button"
        className={`${styles.btn} ${compact ? styles.compact : ""} ${done ? styles.done : ""} ${className ?? ""}`}
        onClick={onClick}
        aria-label={compact ? `Copy ${text}` : undefined}
      >
        <span className={styles.icons} aria-hidden="true">
          <Copy size={compact ? 15 : 17} className={styles.iconCopy} />
          <Check size={compact ? 15 : 17} className={styles.iconCheck} />
        </span>
        <span className={styles.labels} aria-hidden={compact ? true : undefined}>
          <span className={styles.labelCopy}>{compact ? "" : "Copy"}</span>
          <span className={styles.labelDone}>{compact ? (done ? label : "") : label}</span>
        </span>
        {!compact && <span className="sr-only"> command</span>}
      </button>
      <span className="sr-only" role="status" aria-live="polite">{announce}</span>
    </>
  );
}
