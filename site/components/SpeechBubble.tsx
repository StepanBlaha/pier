"use client";

import { useEffect, useReducer } from "react";
import styles from "./SpeechBubble.module.css";

type State = { index: number; shown: number; phase: "hold" | "erase" | "type" };

/** Cycles through short lines with a typewriter effect. Line one is rendered in full for SSR and reduced motion. */
export default function SpeechBubble({ lines }: { lines: string[] }) {
  const [state, tick] = useReducer(
    (s: State): State => {
      if (s.phase === "hold") return { ...s, phase: "erase" };
      if (s.phase === "erase") {
        if (s.shown > 0) return { ...s, shown: s.shown - 1 };
        return { index: (s.index + 1) % lines.length, shown: 0, phase: "type" };
      }
      if (s.shown < lines[s.index].length) return { ...s, shown: s.shown + 1 };
      return { ...s, phase: "hold" };
    },
    { index: 0, shown: lines[0].length, phase: "hold" },
  );

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const delay = state.phase === "hold" ? 2800 : state.phase === "erase" ? 16 : 36;
    const t = setTimeout(tick, delay);
    return () => clearTimeout(t);
  }, [state]);

  return (
    <div className={styles.bubble}>
      <p className="sr-only">The pier gull says: {lines.join(" ")}</p>
      <p className={styles.text} aria-hidden="true">
        {lines[state.index].slice(0, state.shown)}
        <span className={styles.caret} />
      </p>
    </div>
  );
}
