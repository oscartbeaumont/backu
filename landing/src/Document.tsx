import type { ParentProps } from "solid-js";
import { HydrationScript } from "@solidjs/web";

export default function Document(props: ParentProps) {
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="color-scheme" content="light" />
        <meta name="theme-color" content="#fbfaf6" />
        <title>Backu — Every photo, safely in your own cloud</title>
        <link rel="icon" href="/favicon.png" type="image/png" />
        <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
        <link
          rel="preload"
          as="image"
          href="/screens/library.webp"
          type="image/webp"
          fetchpriority="high"
        />
        <HydrationScript />
      </head>
      <body>{props.children}</body>
    </html>
  );
}
