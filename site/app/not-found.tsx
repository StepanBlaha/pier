import type { Metadata } from "next";
import Image from "next/image";
import Link from "next/link";
import ButtonLink from "@/components/Button";
import logo from "@/public/logo.webp";
import surprised from "@/public/mascot/surprised.webp";
import styles from "./not-found.module.css";

export const metadata: Metadata = { title: "Page not found", robots: { index: false } };

export default function NotFound() {
  return (
    <div className={styles.page}>
      <header className={`container ${styles.bar}`}>
        <Link className={styles.brand} href="/" aria-label="pier, back to the home page">
          <Image src={logo} alt="" width={36} height={36} className={styles.logo} sizes="36px" />
          <span className={styles.wordmark}>pier</span>
        </Link>
      </header>

      <main id="main" className={`container ${styles.main}`}>
        <div className={styles.chip} aria-hidden="true">
          <span className={styles.dot} />
          <b>:404</b>
          <span>error</span>
        </div>
        <h1 className={styles.title}>Nothing is listening on this page.</h1>
        <p className={styles.text}>
          The link may be old, or the page never existed. The gull checked every port and came back empty handed.
        </p>
        <ButtonLink href="/" variant="yellow">Back home</ButtonLink>
      </main>

      <Image
        src={surprised}
        alt="The pier gull peeking up from the corner, startled"
        className={styles.gull}
        sizes="(max-width: 760px) 180px, 320px"
      />
    </div>
  );
}
