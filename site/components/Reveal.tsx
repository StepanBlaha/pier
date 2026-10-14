"use client";

import { useRef, type CSSProperties, type ElementType, type ReactNode } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { useGSAP } from "@gsap/react";

gsap.registerPlugin(ScrollTrigger, useGSAP);

type Props = {
  children: ReactNode;
  as?: "div" | "li" | "section" | "article" | "header";
  className?: string;
  style?: CSSProperties;
  /** Seconds to wait before the reveal starts (for staggering siblings). */
  delay?: number;
  /** Start offset in px. */
  y?: number;
};

/**
 * Scroll reveal. The wrapper itself carries the transform, so children keep their own hover transforms.
 * Content is fully visible without JS and with prefers-reduced-motion.
 */
export default function Reveal({ children, as = "div", className, style, delay = 0, y = 28 }: Props) {
  const ref = useRef<HTMLElement | null>(null);
  const Tag = as as ElementType;

  useGSAP(
    () => {
      const el = ref.current;
      if (!el) return;
      const mm = gsap.matchMedia();
      mm.add("(prefers-reduced-motion: no-preference)", () => {
        gsap.from(el, {
          opacity: 0,
          y,
          duration: 0.85,
          delay,
          ease: "power3.out",
          clearProps: "opacity,transform",
          scrollTrigger: { trigger: el, start: "top 90%", once: true },
        });
      });
      return () => mm.revert();
    },
    { scope: ref },
  );

  return (
    <Tag ref={ref} className={className} style={style}>
      {children}
    </Tag>
  );
}
