import { createRouter, defineRoutes } from "@solidjs/router";
import Home from "./pages/Home";
import Privacy from "./pages/Privacy";
import Support from "./pages/Support";
import NotFound from "./pages/NotFound";

const routes = defineRoutes([
  { path: "/", component: Home },
  { path: "/privacy", component: Privacy },
  { path: "/support", component: Support },
  { path: "*404", component: NotFound },
]);

export const Router = createRouter({ routes });
