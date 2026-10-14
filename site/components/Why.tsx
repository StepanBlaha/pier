import Image from "next/image";
import Reveal from "./Reveal";
import SectionHead from "./SectionHead";
import thinking from "@/public/mascot/thinking.webp";
import styles from "./Why.module.css";

function Chrome({ title }: { title: string }) {
  return (
    <div className={styles.chrome} aria-hidden="true">
      <span className={styles.d1} />
      <span className={styles.d2} />
      <span className={styles.d3} />
      <span className={styles.chromeTitle}>{title}</span>
    </div>
  );
}

export default function Why() {
  return (
    <section id="why" className={styles.section} aria-labelledby="why-title">
      <div className="container">
        <Reveal>
          <SectionHead
            id="why-title"
            title="lsof tells you a PID. pier tells you the story."
            aside={
              <Image
                src={thinking}
                alt="The pier gull, hand on chin, thinking about which process owns a port"
                className={styles.gull}
                sizes="(max-width: 760px) 140px, 190px"
              />
            }
          >
            <p>
              “Port 3000 is already in use.” By what? <code>lsof</code> says <code>node 4821 *:3000</code>, which is no help
              when six node processes are running. pier answers with the project, the framework and the branch.
            </p>
          </SectionHead>
        </Reveal>

        <div className={styles.grid}>
          <Reveal>
            <figure className={`${styles.card} ${styles.before}`}>
              <Chrome title="lsof" />
              <pre className={styles.pre} tabIndex={0} aria-label="Output of lsof listing five listening ports with only process names and PIDs">
<span className={styles.cmd}>{`$ lsof -iTCP -sTCP:LISTEN -nP
`}</span>
                <span className={styles.head}>{`COMMAND   PID  USER  NAME
`}</span>
{`node     4821  you   *:3000
node     5012  you   *:4321
node     5377  you   *:5173
Python   6120  you   *:8000
postgres  912  you   *:5432`}
              </pre>
              <figcaption className={styles.caption}>Five listeners. Which one is the shop?</figcaption>
            </figure>
          </Reveal>

          <Reveal delay={0.12}>
            <figure className={`${styles.card} ${styles.after}`}>
              <Chrome title="pier" />
              <pre className={styles.pre} tabIndex={0} aria-label="Output of pier listing the same ports with project, framework and git branch">
                <span className={styles.cmd}>{`$ pier
`}</span>
                <span className={styles.head}>
                  {"  PORT  PROJECT     STACK     "}
                  <span className={styles.hideSm}>BRANCH</span>
                  {"\n"}
                </span>
                {ROWS.map((r) => (
                  <span key={r.port} className={styles.row}>
                    <span className={styles.ok}>●</span>{" "}
                    <span className={styles.port}>{r.port}</span>
                    {"  "}
                    <b className={styles.proj}>{r.project}</b>
                    {r.pad}
                    <span className={styles.stack}>{r.stack}</span>
                    <span className={styles.hideSm}>{r.branch}</span>
                    {"\n"}
                  </span>
                ))}
              </pre>
              <figcaption className={styles.caption}>Same ports. Now with names.</figcaption>
            </figure>
          </Reveal>
        </div>
      </div>
    </section>
  );
}

const ROWS = [
  { port: "3000", project: "acme-store", pad: "  ", stack: "Next.js   ", branch: "main" },
  { port: "4321", project: "docs      ", pad: "  ", stack: "Astro     ", branch: "main" },
  { port: "5173", project: "dashboard ", pad: "  ", stack: "Vite      ", branch: "feat/charts" },
  { port: "8000", project: "acme-api  ", pad: "  ", stack: "FastAPI   ", branch: "main" },
  { port: "5432", project: "PostgreSQL", pad: "  ", stack: "infra     ", branch: "" },
];
