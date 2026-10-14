"use client";

import { useLayoutEffect, useRef, useState, type CSSProperties, type KeyboardEvent } from "react";
import Image from "next/image";
import ls from "@/public/shots/ls.webp";
import hello from "@/public/shots/hello.webp";
import styles from "./ShotTabs.module.css";

const TABS = [
  {
    id: "ls",
    label: "pier",
    src: ls,
    alt: "A terminal running pier: a table of ports 3000, 4321, 5173, 8000, 8080, 9090, 5432 and 11434 with project, framework, health, LAN or local binding and uptime. Below it, pier stale reports the forgotten server on port 8080, up 9 days and idle.",
  },
  {
    id: "hello",
    label: "pier hello",
    src: hello,
    alt: "A terminal running pier hello: a pixel art version of the gull next to a speech bubble that says Ahoy, I'm the pier gull, with a tip about pier mcp.",
  },
] as const;

export default function ShotTabs() {
  const [active, setActive] = useState(0);
  // +1 when moving right (pier -> pier hello), -1 when moving left: panels slide accordingly.
  const [dir, setDir] = useState(1);
  const refs = useRef<(HTMLButtonElement | null)[]>([]);
  const [pill, setPill] = useState<{ x: number; w: number } | null>(null);

  const select = (i: number) => {
    if (i === active) return;
    setDir(i > active ? 1 : -1);
    setActive(i);
  };

  // Sliding pill: measure the active tab (and re-measure on resize / font load).
  useLayoutEffect(() => {
    const measure = () => {
      const el = refs.current[active];
      if (el) setPill({ x: el.offsetLeft, w: el.offsetWidth });
    };
    measure();
    window.addEventListener("resize", measure);
    document.fonts?.ready.then(measure);
    return () => window.removeEventListener("resize", measure);
  }, [active]);

  const onKey = (e: KeyboardEvent) => {
    let next = active;
    if (e.key === "ArrowRight") next = (active + 1) % TABS.length;
    else if (e.key === "ArrowLeft") next = (active - 1 + TABS.length) % TABS.length;
    else if (e.key === "Home") next = 0;
    else if (e.key === "End") next = TABS.length - 1;
    else return;
    e.preventDefault();
    select(next);
    refs.current[next]?.focus();
  };

  return (
    <div className={styles.wrap}>
      <div className={styles.tabs} role="tablist" aria-label="CLI examples" onKeyDown={onKey}>
        <span
          className={styles.pill}
          aria-hidden="true"
          style={pill ? ({ "--x": `${pill.x}px`, "--w": `${pill.w}px` } as CSSProperties) : { opacity: 0 }}
        />
        {TABS.map((t, i) => (
          <button
            key={t.id}
            ref={(el) => { refs.current[i] = el; }}
            type="button"
            role="tab"
            id={`shot-tab-${t.id}`}
            aria-selected={active === i}
            aria-controls={`shot-panel-${t.id}`}
            tabIndex={active === i ? 0 : -1}
            className={`${styles.tab} ${active === i ? styles.active : ""}`}
            onClick={() => select(i)}
          >
            {t.label}
          </button>
        ))}
      </div>
      <div className={styles.stage} style={{ "--dir": dir } as CSSProperties}>
        {TABS.map((t, i) => (
          <div
            key={t.id}
            role="tabpanel"
            id={`shot-panel-${t.id}`}
            aria-labelledby={`shot-tab-${t.id}`}
            aria-hidden={active !== i}
            inert={active !== i}
            className={`${styles.panel} ${active === i ? styles.shown : styles.gone}`}
          >
            <Image src={t.src} alt={t.alt} className={styles.shot} sizes="(max-width: 1200px) 94vw, 1100px" />
          </div>
        ))}
      </div>
    </div>
  );
}
