import Image from "next/image";
import { Terminal } from "lucide-react";
import CopyText from "./CopyText";
import Reveal from "./Reveal";
import SectionHead from "./SectionHead";
import ShotTabs from "./ShotTabs";
import clipboard from "@/public/mascot/clipboard.webp";
import styles from "./CliSection.module.css";

const COMMANDS: { cmd: string; body: string }[] = [
  { cmd: "pier", body: "List everything listening, labeled by project." },
  { cmd: "pier watch", body: "A live, top-like view with keys to open, copy and kill." },
  { cmd: "pier info shop", body: "Path, branch, runtime, owners, CPU, memory and command line." },
  { cmd: "pier open 3000", body: "Open it in your browser, reusing the tab you already have. Add --editor or --terminal." },
  { cmd: "pier stop 3000", body: "Stop it cleanly. Databases ask first." },
  { cmd: "pier stale", body: "Find forgotten dev servers: long uptime, idle, no connections." },
  { cmd: "pier prune", body: "Stop every stale server after one confirmation." },
  { cmd: "pier qr 3000", body: "A QR code of the LAN URL, for testing on your phone." },
  { cmd: "pier free", body: "Print the next free port." },
  { cmd: "pier run", body: "Run your dev script under pier, with logs and exact restarts." },
  { cmd: "pier logs shop -f", body: "Follow the logs of a managed server." },
  { cmd: "pier restart shop", body: "Restart it, even if pier did not start it." },
  { cmd: "pier up", body: "Start a whole pier.yml stack, in dependency order." },
  { cmd: "pier down", body: "Stop that stack again." },
  { cmd: "pier expose 3000", body: "A public HTTPS URL through a Cloudflare quick tunnel." },
  { cmd: "pier mcp", body: "An MCP server so Claude Code can see your services." },
  { cmd: "pier completions --install", body: "Tab completion for live ports and names." },
  { cmd: "pier hello", body: "The gull says hi." },
];

const TERMINALS = ["Terminal.app", "iTerm2", "Ghostty", "kitty", "WezTerm", "Warp", "VS Code", "tmux", "ssh"];

export default function CliSection() {
  return (
    <section id="cli" className={styles.section} aria-labelledby="cli-title">
      <div className="container">
        <Reveal>
          <SectionHead
            id="cli-title"
            title="The whole thing, from your terminal."
            aside={
              <Image
                src={clipboard}
                alt="The pier gull holding a clipboard, ready to check ports off"
                className={styles.gull}
                sizes="(max-width: 760px) 130px, 170px"
              />
            }
          >
            <p>
              Everything the app does is a command away, and the CLI works without the app running. Add <code>--json</code>{" "}
              to any command when a script is the one asking.
            </p>
          </SectionHead>
        </Reveal>

        <Reveal>
          <ShotTabs />
        </Reveal>

        <ul className={styles.grid}>
          {COMMANDS.map((c, i) => (
            <Reveal as="li" key={c.cmd} delay={(i % 3) * 0.06} y={20} className={styles.item}>
              <div className={styles.cell}>
                <CopyText text={c.cmd} textClassName={styles.cmd} buttonClassName={styles.copy} />
                <p className={styles.body}>{c.body}</p>
              </div>
            </Reveal>
          ))}
        </ul>

        <Reveal>
          <div className={styles.any}>
            <span className={styles.anyIcon}><Terminal size={22} aria-hidden="true" /></span>
            <div className={styles.anyText}>
              <h3 className={styles.anyTitle}>Works in any terminal</h3>
              <p>
                It respects <code>NO_COLOR</code>, uses plain 16 colors that read on light and dark themes, and falls back
                to ASCII when it has to. Even the pixel gull degrades to hand drawn ASCII.
              </p>
              <ul className={styles.chips} aria-label="Tested terminals">
                {TERMINALS.map((t) => (
                  <li key={t} className={styles.chip}>{t}</li>
                ))}
              </ul>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  );
}
