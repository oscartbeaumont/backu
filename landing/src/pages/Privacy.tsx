import { Link, Meta, Title } from "@solidjs/meta";
import { absoluteURL, SITE_URL } from "../site";

export default function Privacy() {
  return (
    <>
      <Title>Privacy Policy — Backu</Title>
      <Meta
        name="description"
        content="Backu has no account, no analytics and no developer server. Your photos go only to the storage you configure."
      />
      <Link rel="canonical" href={SITE_URL + "/privacy"} />
      <Meta property="og:type" content="article" />
      <Meta property="og:title" content="Privacy Policy — Backu" />
      <Meta property="og:url" content={SITE_URL + "/privacy"} />
      <Meta property="og:image" content={absoluteURL("/icon.png")} />

      <div class="legal">
        <header class="legal-header">
          <a class="back-link" href="/">
            <span aria-hidden="true">←</span> Back to Backu
          </a>
          <p class="eyebrow">Privacy</p>
          <h1>Privacy Policy</h1>
          <p class="legal-meta">Backu for iPhone, iPad and Mac · Effective 17 November 2026</p>
        </header>

        <div class="legal-card legal-intro">
          <p>
            <strong>The short version:</strong> Backu has no account, no analytics and no developer
            server. Your photos go only to the storage you configure. Face recognition runs on your
            device and its feature vectors never leave it.
          </p>
        </div>

        <section class="legal-card">
          <h2>Who operates Backu</h2>
          <p>
            Backu is an open-source app made by Oscar Beaumont. Questions can be raised on{" "}
            <a href="https://github.com/oscartbeaumont/backu/issues">GitHub</a>.
          </p>

          <h2>What the app accesses</h2>
          <ul>
            <li>
              <strong>Photo library.</strong> With your permission, Backu reads your photos and videos
              to display them, build an on-device index, analyse faces, and back them up. You can
              grant limited access or revoke it at any time in System Settings.
            </li>
            <li>
              <strong>Photo metadata.</strong> Capture date, camera, lens, exposure, dimensions and
              location embedded in your photos are read and stored with the photo's index entry and
              sidecar.
            </li>
            <li>
              <strong>Storage credentials.</strong> The access key ID and secret you enter for an
              S3-compatible service are stored in the system Keychain on your device and are used
              only to sign requests to the endpoint you entered.
            </li>
          </ul>

          <h2>Where your data goes</h2>
          <ul>
            <li>
              Photo files, thumbnails, tags, people names, face boxes and search metadata are uploaded
              only to the buckets you configure. The developer does not operate a server and does not
              receive a copy.
            </li>
            <li>
              Your storage provider processes data under its own privacy policy. Backu has no
              relationship with that provider on your behalf and no ability to read your bucket.
            </li>
            <li>
              Face feature vectors are stored only on your device in a file excluded from iCloud
              device backups. They are never uploaded.
            </li>
            <li>Backu contains no analytics, advertising, tracking or crash-reporting SDK.</li>
          </ul>

          <h2>Retention and deletion</h2>
          <ul>
            <li>You control the storage: delete objects there at any time.</li>
            <li>
              Removing the app deletes its local catalog, search index, previews and face vectors from
              the device. Photos already uploaded remain in your storage until you delete them.
            </li>
            <li>
              “Reset library index” in Settings removes the local index, face groups and cached
              previews without touching your buckets.
            </li>
          </ul>

          <h2>Donations</h2>
          <p>
            The in-app Support card opens GitHub Sponsors in your browser. GitHub processes that visit
            under its own privacy policy; Backu receives only the information GitHub Sponsors makes
            available to a sponsor recipient, and never receives payment details.
          </p>

          <h2>Contact</h2>
          <p>
            For privacy questions, open an issue on{" "}
            <a href="https://github.com/oscartbeaumont/backu/issues">GitHub</a>. Please do not include
            personal information or access keys in a public issue.
          </p>
        </section>
      </div>
    </>
  );
}
