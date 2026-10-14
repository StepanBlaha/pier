"use client";

import { useRef, type CSSProperties, type ReactNode } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { useGSAP } from "@gsap/react";

gsap.registerPlugin(ScrollTrigger, useGSAP);

type Props = {
  children: ReactNode;
  /** Total vertical travel in px while the parent section scrolls out. Negative moves up. */
  distance: number;
  className?: string;
  style?: CSSProperties;
};

/** Light scroll parallax tied to the closest <section>. No motion for prefers-reduced-motion. */
export default function Parallax({ children, distance, className, style }: Props) {
  const ref = useRef<HTMLDivElement>(null);

  useGSAP(
    () => {
      const el = ref.current;
      if (!el) return;
      const trigger = el.closest("section") ?? el;
      const mm = gsap.matchMedia();
      mm.add("(prefers-reduced-motion: no-preference)", () => {
        gsap.to(el, {
          y: distance,
          ease: "none",
          scrollTrigger: { trigger, start: "top top", end: "bottom top", scrub: 0.6 },
        });
      });
      return () => mm.revert();
    },
    { scope: ref },
  );

  return (
    <div ref={ref} className={className} style={style}>
      {children}
    </div>
  );
}
