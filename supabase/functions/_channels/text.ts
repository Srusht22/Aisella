// Byte-exact text handling shared by the ingest and send paths.

/** SHA-256 (hex) of the UTF-8 bytes of `text`, identical to the database's app.sha256_hex. */
export async function sha256Hex(text: string | Uint8Array): Promise<string> {
  const bytes = typeof text === "string" ? new TextEncoder().encode(text) : text;
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes.slice()));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * WhatsApp template rendering, identical to the database's app.render_template: {{1}}..{{n}} replaced
 * by the parameters in order. Parameters never contain "{{" (checked when the seller sends), so the
 * order of replacement cannot change the result.
 */
export function renderTemplate(body: string, params: readonly string[]): string {
  let out = body;
  params.forEach((p, i) => {
    out = out.split(`{{${i + 1}}}`).join(p);
  });
  return out;
}

/** Constant-time comparison of two strings of equal expected length. */
export function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

export async function hmacSha256Hex(secret: string, raw: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, raw.slice()));
  return Array.from(sig, (b) => b.toString(16).padStart(2, "0")).join("");
}
