"use client";

import LocomotiveScroll from "locomotive-scroll";

/**
 * One Locomotive Scroll (v5, Lenis under the hood) instance for the whole page.
 * Native scroll position stays authoritative, so GSAP ScrollTrigger works without a scrollerProxy.
 */
let instance: LocomotiveScroll | null = null;

export function initScroll(): LocomotiveScroll | null {
  if (typeof window === "undefined") return null;
  if (instance) return instance;
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  instance = new LocomotiveScroll({
    lenisOptions: { lerp: reduce ? 1 : 0.11, smoothWheel: !reduce },
  });
  return instance;
}

export function destroyScroll() {
  instance?.destroy();
  instance = null;
}

export function stopScroll() { instance?.stop(); }
export function startScroll() { instance?.start(); }

/** Smoothly scroll to a selector / element / y. Unlock first (a stopped Lenis ignores scrollTo). */
export function scrollToTarget(target: string | HTMLElement | number, offset = -80) {
  startScroll();
  if (instance) {
    const y = typeof target === "number" ? target : undefined;
    const el = typeof target === "string" ? document.querySelector<HTMLElement>(target) : typeof target === "number" ? null : target;
    const distance = el ? Math.abs(el.getBoundingClientRect().top) : Math.abs((y ?? 0) - window.scrollY);
    const duration = Math.min(1.6, Math.max(0.6, distance / 2200));
    instance.scrollTo(el ?? y ?? 0, { offset, duration });
    return;
  }
  if (typeof target === "number") window.scrollTo({ top: target, behavior: "smooth" });
  else (typeof target === "string" ? document.querySelector(target) : target)?.scrollIntoView({ behavior: "smooth" });
}
