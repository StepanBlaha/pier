"use client";

import { useCallback, useEffect, useRef, useState, type MouseEvent } from "react";
import Image from "next/image";
import { Menu, X } from "lucide-react";
import ButtonLink from "./Button";
import GithubIcon from "./GithubIcon";
import { REPO_URL } from "@/lib/site";
import { scrollToTarget, startScroll, stopScroll } from "@/lib/scroll";
import logo from "@/public/logo.webp";
import styles from "./Header.module.css";

const LINKS = [
  { href: "#features", label: "Features" },
  { href: "#app", label: "App" },
  { href: "#cli", label: "CLI" },
  { href: "#claude", label: "Claude Code" },
];

export default function Header() {
  const [scrolled, setScrolled] = useState(false);
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLElement>(null);
  const toggleRef = useRef<HTMLButtonElement>(null);
  const firstLinkRef = useRef<HTMLAnchorElement>(null);

  const close = useCallback((returnFocus: boolean) => {
    setOpen(false);
    startScroll();
    if (returnFocus) toggleRef.current?.focus();
  }, []);

  // Sticky bar gets a blurred cream background once the page has scrolled.
  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  // Menu behaviours: scroll lock, focus into the panel, outside click, Esc, resize.
  useEffect(() => {
    if (!open) return;
    stopScroll();
    firstLinkRef.current?.focus();
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") close(true); };
    const onPointer = (e: PointerEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) close(false);
    };
    const onResize = () => { if (window.innerWidth > 860) close(false); };
    document.addEventListener("keydown", onKey);
    document.addEventListener("pointerdown", onPointer);
    window.addEventListener("resize", onResize);
    return () => {
      document.removeEventListener("keydown", onKey);
      document.removeEventListener("pointerdown", onPointer);
      window.removeEventListener("resize", onResize);
    };
  }, [open, close]);

  useEffect(() => () => startScroll(), []);

  const go = (e: MouseEvent<HTMLAnchorElement>, target: string | number) => {
    e.preventDefault();
    if (open) close(true);
    if (typeof target === "number") scrollToTarget(0, 0);
    else scrollToTarget(target);
  };

  return (
    <header ref={rootRef} className={`${styles.header} ${scrolled || open ? styles.solid : ""}`}>
      <div className={`container ${styles.bar}`}>
        <a className={styles.brand} href="#top" onClick={(e) => go(e, 0)} aria-label="pier, back to top">
          <Image src={logo} alt="" width={36} height={36} className={styles.logo} sizes="36px" />
          <span className={styles.wordmark}>pier</span>
        </a>

        <nav className={styles.nav} aria-label="Primary">
          <ul className={styles.links}>
            {LINKS.map((l) => (
              <li key={l.href}>
                <a className={styles.link} href={l.href} onClick={(e) => go(e, l.href)}>{l.label}</a>
              </li>
            ))}
          </ul>
        </nav>

        <div className={styles.actions}>
          <a className={styles.gh} href={REPO_URL} target="_blank" rel="noopener noreferrer" aria-label="pier on GitHub">
            <GithubIcon size={22} />
            <span className="sr-only"> (opens in a new tab)</span>
          </a>
          <ButtonLink href="#install" size="sm" className={styles.cta} onClick={(e) => go(e, "#install")}>Install</ButtonLink>
          <button
            ref={toggleRef}
            type="button"
            className={styles.toggle}
            aria-expanded={open}
            aria-controls="mobile-menu"
            aria-label={open ? "Close menu" : "Open menu"}
            onClick={() => (open ? close(true) : setOpen(true))}
          >
            {open ? <X size={24} aria-hidden="true" /> : <Menu size={24} aria-hidden="true" />}
          </button>
        </div>
      </div>

      <div id="mobile-menu" className={`${styles.panel} ${open ? styles.panelOpen : ""}`} inert={!open}>
        <ul className={styles.panelList}>
          {LINKS.map((l, i) => (
            <li key={l.href}>
              <a ref={i === 0 ? firstLinkRef : undefined} className={styles.panelLink} href={l.href} onClick={(e) => go(e, l.href)}>
                {l.label}
              </a>
            </li>
          ))}
          <li>
            <a className={styles.panelLink} href={REPO_URL} target="_blank" rel="noopener noreferrer" onClick={() => close(false)}>
              <GithubIcon size={20} />
              <span>GitHub</span>
              <span className="sr-only"> (opens in a new tab)</span>
            </a>
          </li>
        </ul>
      </div>
    </header>
  );
}
