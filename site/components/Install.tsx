import Image from "next/image";
import { Anchor } from "lucide-react";
import CommandBox from "./CommandBox";
import ExtLink from "./ExtLink";
import Reveal from "./Reveal";
import SectionHead from "./SectionHead";
import WalkingGull from "./WalkingGull";
import { APP_INSTALL, BREW_INSTALL, RELEASES_URL, VERSION } from "@/lib/site";
import celebrating from "@/public/mascot/celebrating.webp";
import styles from "./Install.module.css";

export default function Install() {
  return (
    <section id="install" className={styles.section} aria-labelledby="install-title">
      <div className="container">
        <Reveal>
          <SectionHead id="install-title" title="Two commands and you are docked.">
            <p>pier {VERSION} is free and open source under the MIT license, for macOS 14 or later.</p>
          </SectionHead>
        </Reveal>

        <Reveal>
          <div className={styles.card}>
            <Image
              src={celebrating}
              alt="The pier gull celebrating with both wings up"
              className={styles.gull}
              sizes="(max-width: 760px) 120px, 170px"
            />

            <ol className={styles.steps}>
              <li className={styles.step}>
                <span className={styles.num} aria-hidden="true">1</span>
                <div className={styles.stepBody}>
                  <h3 className={styles.stepTitle}>Install the CLI</h3>
                  <CommandBox command={BREW_INSTALL} tone="cream" />
                </div>
              </li>
              <li className={styles.step}>
                <span className={styles.num} aria-hidden="true">2</span>
                <div className={styles.stepBody}>
                  <h3 className={styles.stepTitle}>
                    Add the menu bar app <span className={styles.optional}>optional</span>
                  </h3>
                  <CommandBox command={APP_INSTALL} tone="cream" />
                </div>
              </li>
            </ol>

            <div className={styles.note}>
              <Anchor size={22} aria-hidden="true" />
              <p>
                Builds from source, so macOS never shows a Gatekeeper prompt. The CLI works without the app running.
                Prefer the prebuilt app? Grab the zip from{" "}
                <ExtLink href={RELEASES_URL}>GitHub Releases</ExtLink>.
              </p>
            </div>
          </div>
        </Reveal>
      </div>

      <WalkingGull />
    </section>
  );
}
