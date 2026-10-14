import Image from "next/image";
import { Bot, ShieldCheck } from "lucide-react";
import CommandBox from "./CommandBox";
import CopyText from "./CopyText";
import Reveal from "./Reveal";
import SectionHead from "./SectionHead";
import { MCP_ADD } from "@/lib/site";
import laptop from "@/public/mascot/laptop.webp";
import styles from "./ClaudeSection.module.css";

const PROMPTS = [
  { prompt: "What's running on my machine?", does: "Claude lists your services, labeled by project." },
  { prompt: "Start the docs site and wait until it's healthy.", does: "Claude starts the dev server and waits for it to come up." },
  { prompt: "Show me the last 50 log lines of shop.", does: "Claude reads the logs of a managed server." },
  { prompt: "Is anything stale that I forgot about?", does: "Claude finds servers that have been idle for days." },
];

const CAN = ["List services", "Start and wait until healthy", "Read logs", "Restart or stop", "Find free ports", "Find stale servers"];

export default function ClaudeSection() {
  return (
    <section id="claude" className={styles.section} aria-labelledby="claude-title">
      <div className={`container ${styles.grid}`}>
        <div className={styles.left}>
          <Reveal>
            <SectionHead
              id="claude-title"
              title="Give Claude Code eyes on your localhost."
              aside={
                <Image
                  src={laptop}
                  alt="The pier gull typing away on a laptop"
                  className={styles.gull}
                  sizes="(max-width: 760px) 140px, 170px"
                />
              }
            >
              <p>
                <code>pier mcp</code> is an MCP server. Add it once, and Claude can see and control your local services the
                same way you do.
              </p>
            </SectionHead>
          </Reveal>

          <Reveal delay={0.05}>
            <CommandBox command={MCP_ADD} />
          </Reveal>

          <Reveal delay={0.1}>
            <ul className={styles.can} aria-label="What Claude can do with pier">
              {CAN.map((c) => (
                <li key={c} className={styles.canItem}>{c}</li>
              ))}
            </ul>
            <p className={styles.safety}>
              <ShieldCheck size={22} aria-hidden="true" />
              <span>Stopping a database always needs your explicit confirmation.</span>
            </p>
          </Reveal>
        </div>

        <Reveal className={styles.right} delay={0.1}>
          <div className={styles.chat}>
            <div className={styles.chatBar}>
              <Bot size={18} aria-hidden="true" />
              <span>Try asking Claude Code</span>
            </div>
            <ul className={styles.msgs}>
              {PROMPTS.map((p) => (
                <li key={p.prompt} className={styles.msg}>
                  <div className={styles.bubble}>
                    <CopyText text={p.prompt} tag="span" textClassName={styles.prompt} buttonClassName={styles.copy} />
                  </div>
                  <p className={styles.does}>
                    <Bot size={16} aria-hidden="true" />
                    <span>{p.does}</span>
                  </p>
                </li>
              ))}
            </ul>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
