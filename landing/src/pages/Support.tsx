import { Link, Meta, Title } from "@solidjs/meta";
import { absoluteURL, SITE_URL } from "../site";
import { ArrowIcon } from "../components/Icons";

export default function Support() {
  return (
    <>
      <Title>Support — Backu</Title>
      <Meta
        name="description"
        content="Help with Backu: connecting storage, automatic backup, multiple buckets, privacy and restoring your library."
      />
      <Link rel="canonical" href={SITE_URL + "/support"} />
      <Meta property="og:type" content="article" />
      <Meta property="og:title" content="Support — Backu" />
      <Meta property="og:url" content={SITE_URL + "/support"} />
      <Meta property="og:image" content={absoluteURL("/icon.png")} />

      <div class="legal">
        <header class="legal-header">
          <a class="back-link" href="/">
            <span aria-hidden="true">←</span> Back to Backu
          </a>
          <p class="eyebrow">Support</p>
          <h1>How can we help?</h1>
          <p class="legal-meta">Backu for iPhone, iPad and Mac</p>
        </header>

        <section class="legal-card">
          <h2>Getting started</h2>
          <ol class="support-steps">
            <li>
              Open <strong>Servers</strong> and choose a provider, or <strong>Custom S3</strong>.
            </li>
            <li>
              Follow the numbered steps to create a bucket and an access key. The <strong>Open</strong>{" "}
              button takes you to the right page.
            </li>
            <li>
              Enter the bucket and key, then tap <strong>Test Connection</strong>. Backu lists the
              folder, writes a probe object and reads it back.
            </li>
            <li>
              In <strong>Settings → Backup</strong>, turn on automatic backup and choose one or more
              destinations. The folder prefix is optional.
            </li>
          </ol>
          <p>
            The rest of the library — grid, viewer, tags, people and search — works without a server.
          </p>
        </section>

        <section class="legal-card">
          <h2>Where do my photos go?</h2>
          <p>Into the folder you chose in your storage:</p>
          <ul>
            <li>
              <code>Photos/2025/06/IMG_4821-ab12cd34.jpg</code> — the original file, unchanged.
            </li>
            <li>
              <code>Photos/2025/06/IMG_4821-ab12cd34.jpg.json</code> — tags, people, face boxes, camera,
              location and SHA-256.
            </li>
            <li>
              <code>.backu/thumbs/…</code> and <code>.backu/index.json</code> — previews and a search
              index for your other devices.
            </li>
          </ul>
          <p>
            Nothing is stored on a Backu server. The app uploads directly to the storage you
            configured.
          </p>
        </section>

        <section class="legal-card faq">
          <h2>Common questions</h2>

          <h3>Which providers work?</h3>
          <p>
            Anything with an S3-compatible API: Amazon S3, Backblaze B2, Cloudflare R2, MinIO, Wasabi,
            Synology and custom gateways. Use path-style addressing if your service requires it (most
            appliances do).
          </p>

          <h3>Can I use storage on my own network?</h3>
          <p>
            Yes. Enter the server's LAN address (for example
            <code>http://192.168.1.20:9000</code>). When you connect, iOS asks for Local Network
            access; allow it. Backu never scans your network — it only talks to the address you enter.
          </p>

          <h3>Can I use more than one bucket?</h3>
          <p>
            Yes. Tick several destinations in Settings → Backup. Every selected bucket receives its own
            copy of each photo, so you can keep a redundant off-site copy.
          </p>

          <h3>Do I have to use a folder inside the bucket?</h3>
          <p>
            No. The prefix is optional and can be changed later on the server's detail screen. Leave it
            empty to store photos at the bucket root. Existing uploads keep their paths; new photos use
            the new prefix.
          </p>

          <h3>I got “Access denied”.</h3>
          <p>
            The key needs <code>ListBucket</code>, <code>GetObject</code> and <code>PutObject</code> on
            that bucket. Check the bucket name and region too; a key for another region will fail.
          </p>

          <h3>What happens to the people I name?</h3>
          <p>
            Names and face boxes are written into each photo's sidecar and the shared index, so other
            devices opening the same bucket see them. Face feature vectors stay on the device that
            analysed them.
          </p>

          <h3>How do I restore or open the bucket elsewhere?</h3>
          <p>
            Add the same server on another iPhone, iPad or Mac. Backu reads{" "}
            <code>.backu/index.json</code>, shows previews, and downloads originals when you open them.
          </p>

          <h3>Why did background backup stop?</h3>
          <p>
            iOS decides when background work can run. Force-quitting Backu or turning off Background
            App Refresh in System Settings stops it until you open the app again.
          </p>

          <h3>Is there a subscription?</h3>
          <p>
            No. Backu is free and open source under the MIT licence. If it is useful, you can sponsor
            development from Settings → Support Backu or on{" "}
            <a href="https://github.com/sponsors/oscartbeaumont">GitHub Sponsors</a>.
          </p>
        </section>

        <section class="legal-card support-cta">
          <h2>Still stuck?</h2>
          <p>
            Open an issue and include your iOS or macOS version, your provider and the exact error
            message. Never paste your secret key.
          </p>
          <a class="button" href="https://github.com/oscartbeaumont/backu/issues" target="_blank" rel="noreferrer">
            Report an issue <ArrowIcon class="button-arrow" />
          </a>
        </section>
      </div>
    </>
  );
}
