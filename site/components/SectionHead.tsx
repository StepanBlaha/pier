import type { ReactNode } from "react";
import styles from "./SectionHead.module.css";

type Props = {
  id: string;
  title: ReactNode;
  children?: ReactNode;
  /** Optional visual (usually a gull) placed beside the text on wide screens. */
  aside?: ReactNode;
  className?: string;
};

export default function SectionHead({ id, title, children, aside, className }: Props) {
  return (
    <div className={`${styles.head} ${aside ? styles.withAside : ""} ${className ?? ""}`}>
      <div className={styles.text}>
        <h2 id={id} className={styles.title}>{title}</h2>
        {children && <div className={styles.lead}>{children}</div>}
      </div>
      {aside && <div className={styles.aside}>{aside}</div>}
    </div>
  );
}
