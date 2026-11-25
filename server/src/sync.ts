import { logEvent } from "./log";

/**
 * A place for the library of one person, kept for the apps that share its key (library sync). The device encrypts the
 * document before it leaves, so this Worker and the bucket only ever hold opaque bytes: nothing here reads, parses or logs
 * them, and neither the address of a document (`docId`, derived from the key by the device) nor the write token is logged.
 *
 * One document is the current blob and up to [VERSIONS_KEPT] older ones. A write is conditional (`If-Match` the ETag it
 * was based on, or `If-None-Match: *` for the first one), so that two devices that wrote at once cannot silently drop each
 * other's work: the later one gets 412 and merges what it finds. The first write fixes the write token (kept as a hash in
 * the metadata of the object); after that only a writer who knows it may write or delete.
 */

/** `/sync/<docId>`, with `/versions` or `/v/<time>` after it; the document id is 64 hex digits. */
export const SYNC_ROUTE = /^\/sync\/([0-9a-f]{64})(?:\/(versions)|\/v\/(\d{13}))?$/;

/** The biggest body of a write: a library of thousands of songs is some hundred KB once compressed. */
export const MAX_BLOB_BYTES = 4 * 1024 * 1024;
/** How many old blobs are kept next to the current one. */
const VERSIONS_KEPT = 10;
/**
 * A device writes every few minutes while someone listens, so an old blob is only kept when the newest one kept is at least
 * this old: ten versions then reach back days, not the last hour. The tests shorten it (`SYNC_VERSION_GAP_MS`, 0 keeps all).
 */
const VERSION_GAP_MS = 6 * 60 * 60 * 1000;
/** The write token is made by the device; any string of this length will do. */
const TOKEN_MIN = 16;
const TOKEN_MAX = 128;

const NO_STORE = { "Cache-Control": "no-store" };

function hex(bytes: ArrayBuffer): string {
  return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256(text: string): Promise<string> {
  return hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

/** Compares two hashes (of the same length) without leaking, through timing, how much of a guess was right. */
function sameHash(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

/** The ETag without its quotes and weak mark, so that `"abc"`, `W/"abc"` and `abc` are one tag. */
function bare(etag: string): string {
  return etag.trim().replace(/^W\//, "").replace(/^"|"$/g, "");
}

/** The time of an old blob in the name of its key: 13 digits keep the keys in the order of time. */
function versionKey(id: string, time: number): string {
  return `sync/${id}/v/${String(time).padStart(13, "0")}`;
}

function blobResponse(object: R2ObjectBody): Response {
  return new Response(object.body, {
    headers: { "Content-Type": "application/octet-stream", "Content-Length": String(object.size), ETag: object.httpEtag, ...NO_STORE },
  });
}

/** The old blobs of a document, oldest first (the keys sort by time). */
async function listVersions(bucket: R2Bucket, id: string): Promise<R2Object[]> {
  const found: R2Object[] = [];
  let cursor: string | undefined;
  do {
    const page = await bucket.list({ prefix: `sync/${id}/v/`, cursor });
    found.push(...page.objects);
    cursor = page.truncated ? page.cursor : undefined;
  } while (cursor);
  return found;
}

export async function serveSync(request: Request, env: Env, match: RegExpMatchArray): Promise<Response> {
  const bucket = env.MEDIA;
  if (!bucket) return new Response("Sync is not set up on this server", { status: 503 });
  const [, id, versions, time] = match;
  const current = `sync/${id}/cur`;

  const done = (response: Response): Response => {
    logEvent("sync", { method: request.method, status: response.status });
    return response;
  };

  if (versions || time) {
    if (request.method !== "GET") return done(new Response("Method not allowed", { status: 405, headers: { Allow: "GET" } }));
    if (versions) {
      const list = (await listVersions(bucket, id)).slice(-VERSIONS_KEPT).reverse();
      return done(Response.json(list.map((o) => ({ t: Number(o.key.slice(o.key.lastIndexOf("/") + 1)), size: o.size })), { headers: NO_STORE }));
    }
    const old = await bucket.get(versionKey(id, Number(time)));
    return done(old ? blobResponse(old) : new Response("Not found", { status: 404 }));
  }

  if (request.method === "GET") {
    const object = await bucket.get(current);
    return done(object ? blobResponse(object) : new Response("Not found", { status: 404 }));
  }
  if (request.method !== "PUT" && request.method !== "DELETE") {
    return done(new Response("Method not allowed", { status: 405, headers: { Allow: "GET, PUT, DELETE" } }));
  }

  const token = request.headers.get("X-Sync-Token") ?? "";
  if (token.length < TOKEN_MIN || token.length > TOKEN_MAX) return done(new Response("A write token of 16 to 128 characters is needed", { status: 400 }));
  const tokenHash = await sha256(token);
  const wrongToken = (object: R2Object) => !sameHash(object.customMetadata?.token ?? "", tokenHash);

  if (request.method === "DELETE") {
    const head = await bucket.head(current);
    if (!head) return done(new Response("Not found", { status: 404 }));
    if (wrongToken(head)) return done(new Response("Wrong write token", { status: 403 }));
    // The current blob last: if this stops half way, the document is still there to be deleted again
    const old = await listVersions(bucket, id);
    if (old.length) await bucket.delete(old.map((o) => o.key));
    await bucket.delete(current);
    return done(new Response(null, { status: 204, headers: NO_STORE }));
  }

  const ifMatch = request.headers.get("If-Match");
  const create = request.headers.get("If-None-Match")?.trim() === "*";
  if (ifMatch === null && !create) return done(new Response("If-Match or If-None-Match: * is needed", { status: 428 }));
  const length = request.headers.get("Content-Length");
  if (length !== null && Number(length) > MAX_BLOB_BYTES) return done(new Response("Too big", { status: 413 }));
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_BLOB_BYTES) return done(new Response("Too big", { status: 413 }));

  const stale = (etag?: string) => done(new Response("The document changed", { status: 412, headers: etag ? { ETag: etag, ...NO_STORE } : NO_STORE }));
  const before = await bucket.get(current);
  if (before) {
    if (wrongToken(before)) return done(new Response("Wrong write token", { status: 403 }));
    if (create || bare(ifMatch ?? "") !== bare(before.httpEtag)) return stale(before.httpEtag);
  } else if (!create) {
    return stale();
  }

  // The old blob is copied first, and the new one put only if nobody wrote in between. R2 answers a precondition that fails
  // with null (local `wrangler dev` does, for `etagMatches` and for `etagDoesNotMatch: "*"`; the platform is documented to the
  // same) and some runtimes may throw instead: both mean that the write was lost.
  const at = Date.now();
  const old = await listVersions(bucket, id);
  const gap = env.SYNC_VERSION_GAP_MS !== undefined && Number(env.SYNC_VERSION_GAP_MS) >= 0 ? Number(env.SYNC_VERSION_GAP_MS) : VERSION_GAP_MS;
  const newest = old.length ? Number(old[old.length - 1].key.slice(old[old.length - 1].key.lastIndexOf("/") + 1)) : 0;
  let copy: string | null = null;
  if (before && at - newest >= gap) {
    copy = versionKey(id, at);
    await bucket.put(copy, await before.arrayBuffer(), { httpMetadata: before.httpMetadata, customMetadata: before.customMetadata });
  }
  let saved: R2Object | null = null;
  try {
    saved = await bucket.put(current, body, {
      httpMetadata: { contentType: "application/octet-stream" },
      customMetadata: { token: before ? (before.customMetadata?.token ?? tokenHash) : tokenHash },
      onlyIf: before ? { etagMatches: before.etag } : { etagDoesNotMatch: "*" },
    });
  } catch {
    saved = null;
  }
  if (!saved) {
    if (copy) await bucket.delete(copy);
    return stale((await bucket.head(current))?.httpEtag);
  }

  const kept = copy ? [...old.map((o) => o.key), copy] : old.map((o) => o.key);
  if (kept.length > VERSIONS_KEPT) await bucket.delete(kept.slice(0, kept.length - VERSIONS_KEPT));
  return done(new Response(null, { status: 200, headers: { ETag: saved.httpEtag, ...NO_STORE } }));
}
