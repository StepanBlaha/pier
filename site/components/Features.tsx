import Image from "next/image";
import { Activity, BedDouble, Cloud, Database, FolderGit2, Globe, Layers, QrCode, SquareTerminal, type LucideIcon } from "lucide-react";
import Reveal from "./Reveal";
import SectionHead from "./SectionHead";
import pointing from "@/public/mascot/pointing.webp";
import styles from "./Features.module.css";

const FEATURES: { icon: LucideIcon; title: string; body: string }[] = [
  {
    icon: FolderGit2,
    title: "Knows the project",
    body: "Reads the process’s working directory to name the project, and shows the git branch it is on.",
  },
  {
    icon: Layers,
    title: "Recognizes the framework",
    body: "Next.js, Vite, Astro, Remix, Nuxt, SvelteKit, Rails, Django, Flask, FastAPI, Express and more.",
  },
  {
    icon: Database,
    title: "Names your infra",
    body: "PostgreSQL, Redis, MongoDB, MySQL, Ollama and Docker containers show up by name, not by PID.",
  },
  {
    icon: Globe,
    title: "Page title and favicon",
    body: "A quick probe shows what each port actually serves, so you can tell two localhost tabs apart.",
  },
  {
    icon: Activity,
    title: "Health at a glance",
    body: "Every port is ok, error or timeout, with uptime, CPU and memory next to it.",
  },
  {
    icon: QrCode,
    title: "LAN exposure and QR codes",
    body: "See what is reachable from your network, and scan a QR code to test on your phone.",
  },
  {
    icon: SquareTerminal,
    title: "Who started it",
    body: "VS Code, iTerm, tmux or Claude Code. pier can jump straight back to the terminal that did.",
  },
  {
    icon: BedDouble,
    title: "Finds forgotten servers",
    body: "Servers idle for days get an idle badge, and one click or pier prune cleans them up.",
  },
  {
    icon: Cloud,
    title: "Public URL on demand",
    body: "pier expose opens a Cloudflare quick tunnel and gives you an HTTPS address to share.",
  },
];

export default function Features() {
  return (
    <section id="features" className={styles.section} aria-labelledby="features-title">
      <div className="container">
        <Reveal>
          <SectionHead
            id="features-title"
            title="Everything behind a port, in one glance."
            aside={
              <div className={styles.tile}>
                <Image
                  src={pointing}
                  alt="The pier gull peeking in from the corner and pointing a wing at the headline"
                  className={styles.gull}
                  sizes="(max-width: 760px) 200px, 260px"
                />
              </div>
            }
          >
            <p>
              A listening port is only a number. pier works out the rest, so you never have to guess which dev server
              you are about to kill.
            </p>
          </SectionHead>
        </Reveal>

        <ul className={styles.grid}>
          {FEATURES.map((f, i) => (
            <Reveal as="li" key={f.title} delay={(i % 3) * 0.08} className={styles.item}>
              <article className={styles.card}>
                <span className={styles.icon}>
                  <f.icon size={24} strokeWidth={2} aria-hidden="true" />
                </span>
                <h3 className={styles.title}>{f.title}</h3>
                <p className={styles.body}>{f.body}</p>
              </article>
            </Reveal>
          ))}
        </ul>
      </div>
    </section>
  );
}
