# Backu landing

The consumer landing page and the App Store privacy/support pages.

It runs on **Solid 2** with **`@solidjs/vite-plugin` in start mode** (`start: { nodeServer: true }`, `ssr: true`). There is no SolidStart runtime; the plugin owns the entries, development and preview serving, and the production Node handler.

## Develop

```sh
cd landing
npm install
npm run dev
```

The dev server listens on <http://localhost:3000>.

## Check

```sh
npm run typecheck
npm run build
```

`npm run build` writes:

- `dist/client` — browser assets
- `dist/server/server.js` — web `Request` → `Response` handler
- `dist/server/node.js` — runnable Node server with static file serving

## Run the production build

```sh
PORT=3000 npm start
```

This runs the Node handler emitted by `start.nodeServer`. That is useful for
local production checks; Cloudflare runs the web-standard handler instead.

## Deploy

The site is deployed to Cloudflare Workers as `backu`, with the static client
assets served by Workers Static Assets:

```sh
npx wrangler deploy
```

Configuration lives in `wrangler.jsonc`. The Worker is served at the apex custom
domain <https://backu.otbeaumont.me> through a `custom_domain` route.

`main` is `dist/server/server.js`, the web `Request` → `Response` handler. The
Worker uses the `nodejs_compat` flag because Solid's server runtime imports
`node:async_hooks`. The apex custom domain is configured in `wrangler.jsonc` as
a `custom_domain` route.

The production `workers.dev` route is disabled (`workers_dev: false`) so the
site is only indexed at `backu.otbeaumont.me`. Version URLs stay enabled
(`preview_urls: true`) for PR previews; they are not linked from the production
site.

### CI

`.github/workflows/deploy-landing.yml` type-checks, builds and deploys on every
push to `main` that touches `landing/`:

- `CLOUDFLARE_ACCOUNT_ID` — `f8b7c4b3e3ed4fb3d04a4264e21dd18e`
- `CLOUDFLARE_API_TOKEN` — a scoped token with Workers scripts/routes access
  for `backu.otbeaumont.me`

Both are configured for this repository. The token expires on 17 November
2027; rotate it before then. Until a token is present, the deploy step is
skipped and the workflow still verifies the build. A local `wrangler login`
session can also deploy.

Pull requests that touch `landing/` upload a preview version with a
`pr-<number>` alias and comment its `workers.dev` URL on the PR. Preview
versions do not receive the `backu.otbeaumont.me` custom domain.

To move the site again, update the route in `wrangler.jsonc`, set
`VITE_SITE_URL` at build time, update `public/robots.txt` and
`public/sitemap.xml`, and update the App Store URLs in
`AppStore/metadata/en-US/{marketing,privacy,support}_url.txt`.

## Public TestFlight button

The landing shows **Join the TestFlight** in the hero and the Get Backu card
when `VITE_TESTFLIGHT_URL` is set. With it unset, the page keeps the normal
"See how it works" / "Follow the build" buttons.

To make a public TestFlight link that anyone can use:

1. App Store Connect → Backu → TestFlight → **External Testing**.
2. Create a group (for example `Public Beta`) and add the build.
3. Submit the build for **Beta App Review**. External testers cannot install
   until Apple approves it.
4. Enable **Public Link** for the group and copy the
   `https://testflight.apple.com/join/...` URL.
5. Set the repository variable and deploy the landing:

```sh
gh variable set VITE_TESTFLIGHT_URL --repo oscartbeaumont/backu   --body "https://testflight.apple.com/join/XXXXXXXX"
gh workflow run deploy-landing.yml
```

For local builds:

```sh
VITE_TESTFLIGHT_URL="https://testflight.apple.com/join/XXXXXXXX" npm run build
```

The link enrolls anyone who opens it into that external testing group, subject
to Apple's public-link tester limit and the build's 90-day TestFlight
availability. It is separate for iOS/iPadOS and macOS: each platform needs its
own external group/public link.

## Routes

- `/` — landing
- `/privacy` — privacy policy (App Store privacy URL)
- `/support` — help and FAQ (App Store support URL)

Screenshots live in `public/screens` and are optimised WebP copies of the App
Store shots.
