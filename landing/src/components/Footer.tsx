export default function Footer() {
  return (
    <footer class="footer">
      <div class="footer-inner">
        <div class="footer-brand">
          <a class="brand" href="/">
            <img src="/favicon.png" alt="" width="30" height="30" />
            <span>Backu</span>
          </a>
          <p>Your photos. Your storage. No subscription.</p>
        </div>

        <div class="footer-columns">
          <div class="footer-column">
            <h2>Backu</h2>
            <a href="/#why">Why Backu</a>
            <a href="/#how">How it works</a>
            <a href="/#get">Get Backu</a>
          </div>
          <div class="footer-column">
            <h2>Help</h2>
            <a href="/support">Support</a>
            <a href="/privacy">Privacy policy</a>
            <a href="https://github.com/oscartbeaumont/backu/issues" target="_blank" rel="noreferrer">
              Report a bug
            </a>
          </div>
          <div class="footer-column">
            <h2>Elsewhere</h2>
            <a href="https://github.com/oscartbeaumont/backu" target="_blank" rel="noreferrer">
              GitHub
            </a>
            <a href="https://github.com/sponsors/oscartbeaumont" target="_blank" rel="noreferrer">
              Sponsor
            </a>
          </div>
        </div>
      </div>

      <div class="footer-bottom">
        <span>
          © 2026{" "}
          <a class="footer-author" href="https://otbeaumont.me" target="_blank" rel="noreferrer">
            Oscar Beaumont
          </a>
        </span>
        <span>Free and open source under the MIT licence.</span>
      </div>
    </footer>
  );
}
