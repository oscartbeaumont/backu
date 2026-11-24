import { Meta, Title } from "@solidjs/meta";
import Nav from "./components/Nav";
import Footer from "./components/Footer";
import { Router } from "./router";
import "./styles.css";

export default function App() {
  return (
    <Router>
      {(props) => (
        <>
          <Title>Backu — Every photo, safely in your own cloud</Title>
          <Meta
            name="description"
            content="Backu backs up your whole photo library to storage you already own. No subscription, no account, no middleman. Built for iPhone, iPad and Mac."
          />
          <a class="skip-link" href="#main" onClick={() => document.getElementById("main")?.focus()}>
            Skip to content
          </a>
          <Nav />
          <main id="main" tabindex="-1">{props.children}</main>
          <Footer />
        </>
      )}
    </Router>
  );
}
