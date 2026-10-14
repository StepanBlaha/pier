import Image from "next/image";
import CommandBox from "./CommandBox";
import ButtonLink from "./Button";
import GithubIcon from "./GithubIcon";
import SpeechBubble from "./SpeechBubble";
import { BREW_INSTALL, REPO_URL } from "@/lib/site";
import saluting from "@/public/mascot/saluting.webp";
import styles from "./Hero.module.css";

const LINES = [
  "Ahoy! Who’s on port 3000?",
  ":3000 is acme-store. Next.js, main branch.",
  ":5432 is PostgreSQL. All good.",
  "That one’s been idle for 9 days…",
];

const CHIPS = [
  { port: ":3000", name: "Next.js", pos: "c1", delay: 0.55 },
  { port: ":5173", name: "Vite", pos: "c2", delay: 0.7 },
  { port: ":8000", name: "FastAPI", pos: "c3", delay: 0.85 },
  { port: ":5432", name: "PostgreSQL", pos: "c4", delay: 1.0 },
  { port: ":11434", name: "Ollama", pos: "c5", delay: 1.15 },
] as const;

export default function Hero() {
  return (
    <section id="top" className={styles.hero} aria-labelledby="hero-title">

      <div className={`container ${styles.grid}`}>
        <div className={styles.copy}>
          <h1 id="hero-title" className={`${styles.title} ${styles.in}`} style={{ "--i": 0 } as React.CSSProperties}>
            Who’s on port <span className={styles.port}>3000</span>?
          </h1>
          <p className={`${styles.sub} ${styles.in}`} style={{ "--i": 1 } as React.CSSProperties}>
            pier tells you which project every localhost port belongs to, in your menu bar and your terminal.
          </p>
          <div className={`${styles.install} ${styles.in}`} style={{ "--i": 2 } as React.CSSProperties}>
            <CommandBox command={BREW_INSTALL} />
          </div>
          <div className={`${styles.secondary} ${styles.in}`} style={{ "--i": 3 } as React.CSSProperties}>
            <ButtonLink href={REPO_URL} external variant="white" icon={<GithubIcon size={20} />}>
              View on GitHub
            </ButtonLink>
            <p className={styles.fine}>Free and open source. macOS 14 or later.</p>
          </div>
        </div>

        <div className={styles.stage}>
          <div className={`${styles.bubbleWrap} ${styles.in}`} style={{ "--i": 4 } as React.CSSProperties}>
            <SpeechBubble lines={LINES} />
          </div>

          <div className={styles.gullWrap}>
            <div className={styles.gullPar}>
              <div className={styles.gullIn}>
                  <Image
                    src={saluting}
                    alt="The pier gull, a seagull in a sailor hat, giving a salute"
                    className={styles.gull}
                    sizes="(max-width: 900px) 300px, 440px"
                    preload
                  />
              </div>
            </div>

            <div aria-hidden="true">
              {CHIPS.map((c) => (
                <div key={c.port} className={`${styles.chipPos} ${styles[c.pos]}`}>
                  <div className={styles.chip} style={{ "--d": `${c.delay}s` } as React.CSSProperties}>
                    <span className={styles.dot} />
                    <b className={styles.chipPort}>{c.port}</b>
                    <span>{c.name}</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>

      <svg className={styles.wave} viewBox="0 0 1440 48" preserveAspectRatio="none" aria-hidden="true" focusable="false">
        <path d="M0 24c120 20 240 24 360 8s240-28 360-24 240 28 360 32 240-12 360-28V48H0Z" />
      </svg>
    </section>
  );
}
