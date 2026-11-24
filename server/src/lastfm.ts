import { logEvent } from "./log";

/**
 * Last.fm for the apps. Every call that writes to Last.fm must be signed with a shared secret, and a secret cannot live in an
 * app (the repository and the web bundle are public, an APK can be unpacked), so the app sends the call here and the Worker
 * signs it, as it holds the secret like it holds `ROOM_KEY`. Nothing is kept: the session key and the token cross this
 * route and are never written down or logged.
 *
 * It is not an open proxy: it needs the room key like every other route, takes only the four methods a scrobbler uses, only
 * POST, only a small form, and always asks one address.
 */

export const LASTFM_ROUTE = "/lastfm";

/** What the app may ask: a token to start, the session once the person has allowed it, what plays now, what was heard. */
const METHODS = new Set(["auth.getToken", "auth.getSession", "track.updateNowPlaying", "track.scrobble"]);

/** A call of the app is a few hundred bytes (50 listens at most are some 8 KB); anything near this is not one. */
export const MAX_FORM_BYTES = 16 * 1024;

const API = "https://ws.audioscrobbler.com/2.0/";
const AUTH_PAGE = "https://www.last.fm/api/auth/";
const USER_AGENT = "Sapoche (+https://github.com/tranviethungpv/Sapoche)";

/** What Last.fm sets itself, or does not sign: the app may not choose them. */
const OURS = new Set(["api_key", "api_sig", "format", "callback"]);

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * The `api_sig` of Last.fm: the parameters in the order of their names, each name followed by its value, then the secret,
 * all as MD5. `format` and `callback` are not part of it. Names are compared by code unit, as the specification says (ASCII).
 */
export async function sign(params: Record<string, string>, secret: string): Promise<string> {
  const text =
    Object.keys(params)
      .filter((name) => name !== "format" && name !== "callback")
      .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
      .map((name) => name + params[name])
      .join("") + secret;
  // MD5 is not in the Web Crypto standard, but Workers has it
  return hex(await crypto.subtle.digest("MD5", new TextEncoder().encode(text)));
}

export async function serveLastFm(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
  }
  if (!env.LASTFM_KEY || !env.LASTFM_SECRET) return new Response("Last.fm is not set up on this server", { status: 503 });

  const body = await request.text();
  if (new TextEncoder().encode(body).length > MAX_FORM_BYTES) return new Response("Request too large", { status: 413 });

  const method = new URLSearchParams(body).get("method") ?? "";
  if (!METHODS.has(method)) return new Response("Method not allowed on Last.fm", { status: 400 });

  // A name given twice is refused, so that what is signed is what Last.fm reads
  const params: Record<string, string> = {};
  for (const [name, value] of new URLSearchParams(body)) {
    if (OURS.has(name)) continue;
    if (name in params) return new Response("A parameter twice", { status: 400 });
    params[name] = value;
  }
  params.api_key = env.LASTFM_KEY;
  const form = new URLSearchParams({ ...params, api_sig: await sign(params, env.LASTFM_SECRET), format: "json" });

  let reply: Response;
  try {
    reply = await fetch(env.LASTFM_API ?? API, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": USER_AGENT },
      body: form,
    });
  } catch {
    logEvent("lastfm", { method, status: 502 });
    return new Response("Last.fm cannot be reached", { status: 502 });
  }
  const text = await reply.text();
  logEvent("lastfm", { method, status: reply.status });

  // The page where the person allows the app: the app is not given the API key, so the address is made here
  if (method === "auth.getToken" && reply.ok) {
    try {
      const token = (JSON.parse(text) as { token?: unknown }).token;
      if (typeof token === "string") {
        const url = `${AUTH_PAGE}?api_key=${encodeURIComponent(env.LASTFM_KEY)}&token=${encodeURIComponent(token)}`;
        return Response.json({ token, url }, { headers: { "Cache-Control": "no-store" } });
      }
    } catch {
      // not JSON: handed on as it came
    }
  }
  return new Response(text, {
    status: reply.status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}
