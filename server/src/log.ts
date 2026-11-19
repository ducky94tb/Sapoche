/**
 * The only lines this server writes to Workers Logs (wrangler.jsonc keeps the log of each request off, because the web app
 * puts the room key in the address of its WebSocket). One JSON object per line, about what the room decided: never a
 * client id, a key, the text of a chat or a name, only counts and codes.
 */
export function logEvent(ev: string, fields: Record<string, string | number | boolean> = {}): void {
  console.log(JSON.stringify({ ev, ...fields }));
}

/** An error as one short line. */
export function errorText(error: unknown): string {
  const text = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
  return text.slice(0, 200);
}
