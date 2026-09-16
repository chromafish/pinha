// The browser bundle: the LiveView client plus the console's own scripts,
// built by esbuild from the pinned dependencies.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import "./console.js";
import "./webauthn.js";

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");

const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

// Reachable from the console for `liveSocket.enableDebug()` while developing.
window.liveSocket = liveSocket;
