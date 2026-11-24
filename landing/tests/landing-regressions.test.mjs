import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const read = (path) => readFileSync(new URL("../" + path, import.meta.url), "utf8");
const css = read("src/styles.css");
const app = read("src/App.tsx");
const support = read("src/pages/Support.tsx");

function declaration(source, name) {
  const match = source.match(new RegExp("(?:^|;)\\s*" + name + "\\s*:\\s*([^;]+);"));
  assert.ok(match, "missing CSS declaration " + name);
  return match[1].trim();
}

function ruleBody(selector) {
  const escaped = selector.replace(/[.*+?^$()|[\]\\{}]/g, "\\$&");
  const match = css.match(new RegExp(escaped + "\\s*\\{([^}]*)\\}"));
  assert.ok(match, "missing CSS rule " + selector);
  return match[1];
}

function luminance(hex) {
  const channels = hex.match(/[\da-f]{2}/gi).map((value) => parseInt(value, 16) / 255);
  const linear = channels.map((value) =>
    value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4,
  );
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrast(foreground, background) {
  const a = luminance(foreground);
  const b = luminance(background);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

test("small faint text meets WCAG AA contrast on the page background", () => {
  const foreground = declaration(css, "--faint").replace("#", "");
  const background = declaration(css, "--bg").replace("#", "");
  const ratio = contrast(foreground, background);
  assert.ok(
    ratio >= 4.5,
    "--faint on --bg is " + ratio.toFixed(2) + ":1; normal text needs at least 4.5:1",
  );
});

test("the skip-link target is programmatically focusable", () => {
  const main = app.match(/<main\b[^>]*\bid="main"[^>]*>/)?.[0];
  assert.ok(main, "missing main#main skip-link target");
  assert.match(main, /\btabindex="-1"/, "main#main must accept focus without joining the Tab order");
  assert.match(app, /getElementById\("main"\)\?\.focus\(\)/, "activating the skip link must move focus to main#main");
});

test("long support paths can wrap inside narrow legal cards", () => {
  const codeRule = ruleBody(".legal code");
  assert.match(
    codeRule,
    /overflow-wrap:\s*(?:anywhere|break-word)|word-break:\s*break-all/,
    "legal code needs a wrapping fallback for 320px viewports",
  );
  assert.match(support, /Photos\/2025\/06\/IMG_4821-ab12cd34\.jpg\.json/);
});
