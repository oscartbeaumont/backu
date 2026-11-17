/**
 * The public address of the landing. Override with VITE_SITE_URL when the
 * site moves to a custom domain; keep the App Store metadata URLs in sync.
 */
export const SITE_URL = import.meta.env.VITE_SITE_URL ?? "https://backu.otbeaumont.me";

export const absoluteURL = (path: string) => `${SITE_URL}${path}`;
