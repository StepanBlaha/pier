"use client";

import { useRef, type ReactNode } from "react";
import CopyButton from "./CopyButton";

type Props = {
  text: string;
  children?: ReactNode;
  textClassName?: string;
  buttonClassName?: string;
  tag?: "code" | "span";
};

/** Renders a text and its compact copy button as siblings (place inside your own flex container). */
export default function CopyText({ text, children, textClassName, buttonClassName, tag = "code" }: Props) {
  const ref = useRef<HTMLElement | null>(null);
  const Tag = tag;
  return (
    <>
      <Tag ref={ref} className={textClassName}>{children ?? text}</Tag>
      <CopyButton text={text} targetRef={ref} compact className={buttonClassName} />
    </>
  );
}
