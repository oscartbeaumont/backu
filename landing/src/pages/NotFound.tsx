import { Meta, Title } from "@solidjs/meta";
import { httpStatus } from "@solidjs/web";
import { ArrowIcon } from "../components/Icons";

export default function NotFound() {
  httpStatus(404);
  return (
    <>
      <Title>Page not found — Backu</Title>
      <Meta name="robots" content="noindex" />
      <div class="legal">
        <header class="legal-header">
          <p class="eyebrow">404</p>
          <h1>That page moved on.</h1>
          <p class="legal-meta">The photo is still safe. This link just isn't here.</p>
        </header>
        <section class="legal-card">
          <p>Try the landing page, or jump straight to support or the privacy policy.</p>
          <div class="get-actions" style={{ "justify-content": "flex-start", "margin-top": "20px" }}>
            <a class="button" href="/">
              Back to Backu <ArrowIcon class="button-arrow" />
            </a>
            <a class="button button-quiet" href="/support">
              Support
            </a>
          </div>
        </section>
      </div>
    </>
  );
}
