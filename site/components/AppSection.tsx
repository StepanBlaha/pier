import Image from "next/image";
import { BatteryFull, BedDouble, MousePointerClick, PanelRight, Pin, Play, Search, Wifi, type LucideIcon } from "lucide-react";
import Reveal from "./Reveal";
import SectionHead from "./SectionHead";
import logo from "@/public/logo.webp";
import menu from "@/public/shots/menu.webp";
import waving from "@/public/mascot/waving.webp";
import styles from "./AppSection.module.css";

const ITEMS: { icon: LucideIcon; title: string; body: string }[] = [
  { icon: Search, title: "Search everything.", body: "Find a service by project, port, framework or name." },
  { icon: MousePointerClick, title: "One row per project.", body: "Every port a project listens on becomes a chip on its row. Hover for open, copy URL, logs, restart and stop." },
  { icon: PanelRight, title: "A details panel.", body: "Health, branch, URLs, a QR code for your phone, and who started it." },
  { icon: BedDouble, title: "Clean up stale servers.", body: "Forgotten ones get an “idle 9d” badge, and one click stops them." },
  { icon: Play, title: "Stacks and Run…", body: "Bring a pier.yml stack up or down, or start a project’s dev server." },
  { icon: Pin, title: "Pins, renames, crash alerts.", body: "Keep what matters on top and get a notification when a managed server crashes." },
];

export default function AppSection() {
  return (
    <section id="app" className={styles.section} aria-labelledby="app-title">
      <div className={`container ${styles.grid}`}>
        <Reveal className={styles.visual}>
          <figure className={styles.frame}>
            <div className={styles.menubar} aria-hidden="true">
              <Wifi size={16} />
              <BatteryFull size={18} />
              <span className={styles.trayItem}>
                <Image src={logo} alt="" width={20} height={20} sizes="20px" className={styles.trayLogo} />
                <b>8</b>
              </span>
            </div>
            <div className={styles.popover}>
              <Image
                src={menu}
                alt="The pier menu bar popover: a search field, projects Acme Store, Acme Docs, Dashboard, Acme API and prototype with health dots, an infra section with PostgreSQL, Redis and Ollama, and a Clean up 1 stale button."
                className={styles.shot}
                sizes="(max-width: 520px) 90vw, 380px"
              />
            </div>
            <figcaption className={styles.caption}>The gull is your menu bar icon.</figcaption>
          </figure>
        </Reveal>

        <div className={styles.copy}>
          <Reveal>
            <SectionHead
              id="app-title"
              title="Your localhost, one hotkey away."
              aside={
                <Image
                  src={waving}
                  alt="The pier gull waving hello"
                  className={styles.gull}
                  sizes="(max-width: 760px) 120px, 150px"
                />
              }
            >
              <p>
                Press{" "}
                <span className={styles.keys} role="img" aria-label="Option Command P">
                  <kbd className={styles.kbd}>⌥</kbd>
                  <kbd className={styles.kbd}>⌘</kbd>
                  <kbd className={styles.kbd}>P</kbd>
                </span>{" "}
                anywhere, type a few letters, hit return.
              </p>
            </SectionHead>
          </Reveal>

          <ul className={styles.list}>
            {ITEMS.map((it, i) => (
              <Reveal as="li" key={it.title} delay={i * 0.05} className={styles.li}>
                <span className={styles.icon}>
                  <it.icon size={20} aria-hidden="true" />
                </span>
                <p>
                  <b>{it.title}</b> {it.body}
                </p>
              </Reveal>
            ))}
          </ul>
        </div>
      </div>
    </section>
  );
}
