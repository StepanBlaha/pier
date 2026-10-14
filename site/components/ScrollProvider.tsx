"use client";

import { useEffect } from "react";
import { gsap } from "gsap";
import { ScrollTrigger } from "gsap/ScrollTrigger";
import { destroyScroll, initScroll } from "@/lib/scroll";

gsap.registerPlugin(ScrollTrigger);

/** Boots Locomotive Scroll once and keeps ScrollTrigger in sync with it. */
export default function ScrollProvider() {
  useEffect(() => {
    initScroll();
    const refresh = () => ScrollTrigger.refresh();
    window.addEventListener("load", refresh);
    return () => {
      window.removeEventListener("load", refresh);
      destroyScroll();
    };
  }, []);
  return null;
}
