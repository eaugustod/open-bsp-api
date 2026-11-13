// Polyfill process environment for npm compatibility in Deno (required by google-logging-utils)
import process from "node:process";
// @ts-ignore
globalThis.process = process;
// @ts-ignore
globalThis.process.env = process.env || {};
// @ts-ignore
globalThis.process.env.GOOGLE_SDK_NODE_LOGGING = "false";

import { serveDir } from "@std/http/file-server";
import { handleRequest as whatsappWebhook } from "./supabase/functions/whatsapp-webhook/index.ts";
import { handleRequest as whatsappDispatcher } from "./supabase/functions/whatsapp-dispatcher/index.ts";
import { app as whatsappManagementApp } from "./supabase/functions/whatsapp-management/index.ts";
import { handleRequest as notifications } from "./supabase/functions/notifications/index.ts";

const PORT = Number(Deno.env.get("PORT") || 8080);
const UI_DIST = "./ui/dist";

console.log(`[OpenBSP] Gateway starting on port ${PORT}...`);
console.log(`[OpenBSP] Database Schema target: ${Deno.env.get("SUPABASE_DB_SCHEMA") || "openbsp"}`);

Deno.serve({ port: PORT }, async (req: Request) => {
  const url = new URL(req.url);
  let pathname = url.pathname;

  // Normalise Supabase Edge Function prefix if called as /functions/v1/<fn>
  if (pathname.startsWith("/functions/v1/")) {
    pathname = pathname.replace("/functions/v1", "");
    const newUrl = new URL(url.toString());
    newUrl.pathname = pathname;
    req = new Request(newUrl.toString(), req);
  }

  // Healthcheck endpoints
  if (pathname === "/healthz" || pathname === "/health" || pathname === "/ping") {
    return new Response(
      JSON.stringify({
        status: "healthy",
        uptime: performance.now(),
        schema: Deno.env.get("SUPABASE_DB_SCHEMA") || "openbsp",
        time: new Date().toISOString(),
      }),
      {
        headers: { "content-type": "application/json" },
      },
    );
  }

  // Route 1: WhatsApp Webhook (Meta incoming events & verification)
  if (pathname === "/whatsapp-webhook" || pathname === "/whatsapp-webhook/") {
    return await whatsappWebhook(req);
  }

  // Route 2: WhatsApp Dispatcher (outgoing messages sent by database triggers)
  if (pathname === "/whatsapp-dispatcher" || pathname === "/whatsapp-dispatcher/") {
    return await whatsappDispatcher(req);
  }

  // Route 3: WhatsApp Management (Hono app for templates, signup, OAuth)
  if (pathname.startsWith("/whatsapp-management")) {
    return await whatsappManagementApp.fetch(req);
  }

  // Route 4: Media Preprocessor (Lazy loaded on demand to save RAM)
  if (pathname === "/media-preprocessor" || pathname === "/media-preprocessor/") {
    try {
      const { handleRequest } = await import("./supabase/functions/media-preprocessor/index.ts");
      return await handleRequest(req);
    } catch (err) {
      console.error("[OpenBSP] Error in media-preprocessor:", err);
      return new Response("Media preprocessing error", { status: 500 });
    }
  }

  // Route 5: Notifications
  if (pathname === "/notifications" || pathname === "/notifications/") {
    return await notifications(req);
  }

  // Frontend UI Static Files (with SPA fallback to index.html)
  try {
    const res = await serveDir(req, {
      fsRoot: UI_DIST,
      quiet: true,
    });
    if (res.status === 404 && req.method === "GET") {
      try {
        const file = await Deno.open(`${UI_DIST}/index.html`, { read: true });
        return new Response(file.readable, {
          headers: { "content-type": "text/html; charset=utf-8" },
        });
      } catch {
        return res;
      }
    }
    return res;
  } catch (err) {
    console.error("[OpenBSP] Error serving UI static file:", err);
    return new Response("Not found", { status: 404 });
  }
});
