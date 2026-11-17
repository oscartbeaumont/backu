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

## Deploy

The site is deployed to Railway as the `backu-landing` project from this directory:

```sh
railway link        # select the backu-landing project
railway up -y
```

Production URL: <https://backu-landing-production.up.railway.app>

If the site moves to a custom domain, set `VITE_SITE_URL` at build time, update
`public/robots.txt` and `public/sitemap.xml`, and update the App Store URLs in
`AppStore/metadata/en-US/{marketing,privacy,support}_url.txt`.

## Routes

- `/` — landing
- `/privacy` — privacy policy (App Store privacy URL)
- `/support` — help and FAQ (App Store support URL)

Screenshots live in `public/screens` and are optimised WebP copies of the App
Store shots.
