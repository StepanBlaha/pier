"use client";

import { useRef } from "react";
import Image from "next/image";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { useGSAP } from "@gsap/react";
import walking from "@/public/mascot/walking.webp";
import styles from "./WalkingGull.module.css";

gsap.registerPlugin(ScrollTrigger, useGSAP);

/** A gull that walks along the pier deck as the install section scrolls past. Clipped by the section. */
export default function WalkingGull() {
  const track = useRef<HTMLDivElement>(null);
  const walker = useRef<HTMLDivElement>(null);

  useGSAP(
    () => {
      const trackEl = track.current;
      const walkerEl = walker.current;
      if (!trackEl || !walkerEl) return;
      const mm = gsap.matchMedia();
      mm.add("(prefers-reduced-motion: no-preference)", () => {
        gsap.fromTo(
          walkerEl,
          { x: 0 },
          {
            x: () => trackEl.clientWidth - walkerEl.offsetWidth,
            ease: "none",
            scrollTrigger: {
              trigger: trackEl.closest("section") ?? trackEl,
              start: "top bottom",
              end: "bottom bottom",
              scrub: 0.5,
              invalidateOnRefresh: true,
            },
          },
        );
      });
      return () => mm.revert();
    },
    { scope: track },
  );

  return (
    <div ref={track} className={styles.track} aria-hidden="true">
      <div ref={walker} className={styles.walker}>
        <Image src={walking} alt="" className={styles.gull} sizes="88px" />
      </div>
      <div className={styles.deck} />
    </div>
  );
}
