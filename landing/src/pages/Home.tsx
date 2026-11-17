import { Link, Meta, Title } from "@solidjs/meta";
import { For } from "solid-js";
import { revealOnScroll, tiltOnPointer } from "../components/motion";
import { absoluteURL, SITE_URL } from "../site";
import {
  ArrowIcon,
  BucketIcon,
  CheckIcon,
  CloudCheckIcon,
  FaceIcon,
  GitHubIcon,
  LockIcon,
  SearchIcon,
  ShieldIcon,
  SparkleIcon,
} from "../components/Icons";

const features = [
  {
    title: "Backs up while you sleep",
    body: "Every photo and video, backed up automatically in the background. Use Wi-Fi only, or let it run on mobile data.",
    tint: "blue",
    icon: CloudCheckIcon,
  },
  {
    title: "Your storage, your rules",
    body: "Amazon S3, Backblaze B2, Cloudflare R2, MinIO or any S3-compatible bucket. No middleman, no markup.",
    tint: "sun",
    icon: BucketIcon,
  },
  {
    title: "Two copies, zero worry",
    body: "Choose more than one bucket and every photo is saved to each. If one provider goes away, your memories don't.",
    tint: "mint",
    icon: ShieldIcon,
  },
  {
    title: "Find any moment",
    body: "Search by person, place, camera, tag or year. Results appear as you type, even when you're offline.",
    tint: "violet",
    icon: SearchIcon,
  },
  {
    title: "Faces and pets, named",
    body: "Backu recognises the people and animals in your photos, right on your device. You give them names.",
    tint: "coral",
    icon: FaceIcon,
  },
  {
    title: "Private from the start",
    body: "No account, no ads, no analytics. Photos travel straight from your phone to the storage you chose.",
    tint: "sky",
    icon: LockIcon,
  },
] as const;

const steps = [
  {
    number: "01",
    title: "Connect your storage",
    body: "Pick a provider or any S3-compatible bucket. Backu tests the connection before it saves anything.",
  },
  {
    number: "02",
    title: "Choose what to keep safe",
    body: "Photos, videos and screenshots. One bucket or several. Mobile data on or off. It's up to you.",
  },
  {
    number: "03",
    title: "Forget about it",
    body: "New photos upload in the background. Open Backu whenever you want to browse, search or rediscover.",
  },
];

const providers = ["Amazon S3", "Backblaze B2", "Cloudflare R2", "MinIO", "Wasabi", "Synology"];

export default function Home() {
  return (
    <>
      <Title>Backu — Every photo, safely in your own cloud</Title>
      <Meta
        name="description"
        content="Back up your whole photo library to storage you already own. No subscription, no account, no middleman. Built for iPhone, iPad and Mac."
      />
      <Link rel="canonical" href={SITE_URL + "/"} />
      <Meta property="og:type" content="website" />
      <Meta property="og:title" content="Backu — Every photo, safely in your own cloud" />
      <Meta
        property="og:description"
        content="Back up your whole photo library to storage you already own. No subscription, no account, no middleman."
      />
      <Meta property="og:url" content={SITE_URL + "/"} />
      <Meta property="og:image" content={absoluteURL("/icon.png")} />
      <Meta name="twitter:card" content="summary_large_image" />

      <section class="hero" aria-labelledby="hero-title">
        <div class="hero-glow hero-glow-blue" aria-hidden="true" />
        <div class="hero-glow hero-glow-coral" aria-hidden="true" />

        <div class="hero-inner">
          <div class="hero-copy">
            <p class="eyebrow rise rise-1">
              <span class="eyebrow-dot" />
              For iPhone, iPad and Mac
            </p>
            <h1 id="hero-title" class="rise rise-2">
              Every photo.
              <br />
              Safely in your <span class="highlight">own</span> cloud.
            </h1>
            <p class="hero-lede rise rise-3">
              Backu keeps your whole library backed up to storage you already have — without a monthly
              fee, an account, or a catch.
            </p>
            <div class="hero-actions rise rise-4">
              <a class="button" href="#how">
                See how it works
                <ArrowIcon class="button-arrow" />
              </a>
              <a class="button button-quiet" href="#get">
                Get Backu
              </a>
            </div>
            <ul class="hero-trust rise rise-5">
              <li>
                <CheckIcon /> No subscription
              </li>
              <li>
                <CheckIcon /> No account
              </li>
              <li>
                <CheckIcon /> Your photos stay yours
              </li>
            </ul>
          </div>

          <div class="hero-visual rise rise-device" ref={tiltOnPointer}>
            <div class="stage">
              <div class="stage-orb stage-orb-blue" aria-hidden="true" />
              <div class="stage-orb stage-orb-coral" aria-hidden="true" />

              <div class="phone-float">
                <div class="phone-tilt">
                  <div class="phone">
                    <div class="phone-screen">
                      <img
                        src="/screens/library.webp"
                        alt="The Backu photo library on an iPhone"
                        width="900"
                        height="1955"
                        fetchpriority="high"
                        decoding="async"
                      />
                    </div>
                  </div>
                </div>
              </div>

              <div class="float-card card-backup" aria-hidden="true">
                <span class="float-icon float-icon-mint">
                  <CheckIcon />
                </span>
                <span>
                  <strong>Backed up</strong>
                  <small>2,184 photos</small>
                </span>
              </div>

              <div class="float-card card-private" aria-hidden="true">
                <span class="float-icon float-icon-blue">
                  <LockIcon />
                </span>
                <span>
                  <strong>Private by design</strong>
                  <small>On-device AI</small>
                </span>
              </div>

              <div class="float-card card-copies" aria-hidden="true">
                <span class="float-icon float-icon-sun">
                  <ShieldIcon />
                </span>
                <span>
                  <strong>2 copies</strong>
                  <small>Home + Offsite</small>
                </span>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="providers" aria-label="Supported storage providers">
        <p ref={revealOnScroll}>Works with the storage you already pay for</p>
        <div class="provider-list" ref={revealOnScroll}>
          <For each={providers}>
            {(provider) => <span>{provider}</span>}
          </For>
        </div>
      </section>

      <section class="section features" id="why" aria-labelledby="why-title">
        <div class="section-heading" ref={revealOnScroll}>
          <p class="eyebrow">Why Backu</p>
          <h2 id="why-title">Everything a photo app should be.</h2>
          <p class="section-lede">
            Simple on the surface. Serious about keeping your memories safe underneath.
          </p>
        </div>

        <div class="feature-grid">
          <For each={features}>
            {(feature, index) => (
              <article
                class="feature-card"
                ref={revealOnScroll}
                style={`--delay: ${index() * 55}ms`}
              >
                <span class={`feature-icon feature-icon-${feature.tint}`}>
                  <feature.icon />
                </span>
                <h3>{feature.title}</h3>
                <p>{feature.body}</p>
              </article>
            )}
          </For>
        </div>
      </section>

      <section class="section showcase" aria-labelledby="library-title">
        <div class="showcase-panel" ref={revealOnScroll}>
          <div class="showcase-copy">
            <p class="eyebrow">The library</p>
            <h2 id="library-title">It feels like Photos. It's yours.</h2>
            <p>
              The grid, the zoom, the little details — Backu is designed to feel familiar from the
              first tap. Your library, without handing it to someone else.
            </p>
            <ul class="check-list">
              <li>
                <CheckIcon /> Pinch, swipe and zoom through every year
              </li>
              <li>
                <CheckIcon /> Tags, details, favourites and people
              </li>
              <li>
                <CheckIcon /> The same library on iPhone, iPad and Mac
              </li>
            </ul>
            <a class="text-link" href="/support">
              Take a closer look <ArrowIcon class="text-link-arrow" />
            </a>
          </div>
          <div class="showcase-visual">
            <div class="ipad">
              <img
                src="/screens/ipad.webp"
                alt="Backu running on an iPad with the library, people and settings sidebar"
                width="1200"
                height="1600"
                loading="lazy"
                decoding="async"
              />
            </div>
            <div class="search-pill" aria-hidden="true">
              <SearchIcon />
              <span>maple</span>
              <span class="search-pill-badge">People</span>
            </div>
          </div>
        </div>
      </section>

      <section class="section how" id="how" aria-labelledby="how-title">
        <div class="section-heading" ref={revealOnScroll}>
          <p class="eyebrow">How it works</p>
          <h2 id="how-title">Three minutes to set up. Then it just works.</h2>
          <p class="section-lede">No technical knowledge needed. If you can copy a key, you can do this.</p>
        </div>

        <div class="step-grid">
          <For each={steps}>
            {(step, index) => (
              <article class="step" ref={revealOnScroll} style={`--delay: ${index() * 70}ms`}>
                <span class="step-number">{step.number}</span>
                <h3>{step.title}</h3>
                <p>{step.body}</p>
              </article>
            )}
          </For>
        </div>
      </section>

      <section class="section privacy-band" id="privacy" aria-labelledby="privacy-title">
        <div class="privacy-card" ref={revealOnScroll}>
          <div class="privacy-mark">
            <LockIcon />
          </div>
          <div class="privacy-copy">
            <p class="eyebrow">Private by design</p>
            <h2 id="privacy-title">Your memories don't pass through us.</h2>
            <p>
              Backu talks straight to your storage. There is no Backu account and no developer server
              in the middle. Face recognition happens on your device, and what it learns never leaves
              it.
            </p>
            <div class="privacy-chips">
              <span>No analytics</span>
              <span>No ads</span>
              <span>No tracking</span>
            </div>
            <a class="text-link" href="/privacy">
              Read the privacy policy <ArrowIcon class="text-link-arrow" />
            </a>
          </div>
        </div>
      </section>

      <section class="section get" id="get" aria-labelledby="get-title">
        <div class="get-card" ref={revealOnScroll}>
          <div class="get-glow get-glow-blue" aria-hidden="true" />
          <div class="get-glow get-glow-coral" aria-hidden="true" />
          <img class="get-icon" src="/apple-touch-icon.png" alt="" width="88" height="88" loading="lazy" />
          <p class="eyebrow">Coming soon</p>
          <h2 id="get-title">Your photos deserve a safer home.</h2>
          <p>
            Backu is being polished for the App Store on iPhone, iPad and Mac. Follow along, or help
            test the next build.
          </p>
          <div class="get-actions">
            <a class="button" href="https://github.com/oscartbeaumont/backu" target="_blank" rel="noreferrer">
              <GitHubIcon class="button-icon" /> Follow the build
            </a>
            <a class="button button-quiet" href="/support">
              Ask a question
            </a>
          </div>
          <p class="get-note">
            <SparkleIcon /> Free and open source. No subscription, ever.
          </p>
        </div>
      </section>
    </>
  );
}
