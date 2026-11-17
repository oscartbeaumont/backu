import { useLocation } from "@solidjs/router";
import { GitHubIcon } from "./Icons";

export default function Nav() {
  const location = useLocation();
  const onHome = () => location.pathname === "/";
  const section = (hash: string) => (onHome() ? hash : `/${hash}`);

  return (
    <header class="nav">
      <div class="nav-inner">
        <a class="brand" href="/" aria-label="Backu home">
          <img src="/favicon.png" alt="" width="34" height="34" />
          <span>Backu</span>
        </a>

        <nav class="nav-links" aria-label="Main">
          <a href={section("#why")}>Why Backu</a>
          <a href={section("#how")}>How it works</a>
          <a href={section("#privacy")}>Privacy</a>
        </nav>

        <div class="nav-actions">
          <a class="icon-button" href="https://github.com/oscartbeaumont/backu" target="_blank" rel="noreferrer" aria-label="Backu on GitHub">
            <GitHubIcon />
          </a>
          <a class="button button-small" href={section("#get")}>
            Get Backu
          </a>
        </div>
      </div>
    </header>
  );
}
