import Image from "next/image";
import ExtLink from "./ExtLink";
import Copyright from "./Copyright";
import { AUTHOR, REPO_URL, RELEASES_URL } from "@/lib/site";
import sleeping from "@/public/mascot/sleeping.webp";
import styles from "./Footer.module.css";

const LINKS = [
  { href: REPO_URL, label: "GitHub" },
  { href: RELEASES_URL, label: "Releases" },
  { href: `${REPO_URL}/blob/main/CHANGELOG.md`, label: "Changelog" },
  { href: `${REPO_URL}/security/policy`, label: "Security" },
  { href: AUTHOR.url, label: "stepanblaha.com" },
];

export default function Footer() {
  return (
    <footer className={styles.footer}>
      <div className={`container ${styles.top}`}>
        <div className={styles.sleep}>
          <div className={styles.gullWrap}>
            <Image
              src={sleeping}
              alt="The pier gull fast asleep"
              className={styles.gull}
              sizes="(max-width: 760px) 120px, 150px"
            />
            <span className={styles.zz} aria-hidden="true"><i>z</i><i>z</i><i>z</i></span>
          </div>
          <p className={styles.line}>Nothing listening down here.</p>
        </div>

        <nav aria-label="Footer">
          <ul className={styles.links}>
            {LINKS.map((l) => (
              <li key={l.label}>
                <ExtLink href={l.href}>{l.label}</ExtLink>
              </li>
            ))}
          </ul>
        </nav>
      </div>

      <div className={`container ${styles.bottom}`}>
        <p><Copyright /></p>
        <p>MIT licensed. Made for people with too many dev servers.</p>
      </div>
    </footer>
  );
}
