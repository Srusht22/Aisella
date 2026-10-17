// The model's output contract (Phase 3 AI §7). The same rules are enforced again by the database
// (app.ai_output_errors); this copy lets the worker reject a bad answer and retry once before
// spending a database round trip.

export const INTENTS = [
  "price_inquiry",
  "availability_inquiry",
  "product_details",
  "recommendation",
  "delivery_inquiry",
  "policy_inquiry",
  "payment_inquiry",
  "place_order",
  "order_status",
  "modify_order",
  "greeting",
  "other",
] as const;
export const FACTS = [
  "store_name",
  "product_name",
  "variant_label",
  "variant_price",
  "variant_availability",
  "zone_name",
  "zone_fee",
  "zone_time_text",
  "policy_text",
  "payment_methods",
] as const;
export const MISSING = [
  "product",
  "variant",
  "quantity",
  "customer_name",
  "customer_phone",
  "zone",
  "area",
  "payment_method",
] as const;
export const ESCALATIONS = [
  "complaint",
  "refund_or_dispute",
  "discount_request",
  "health_or_safety",
  "authenticity_dispute",
  "abuse",
  "modify_approved_order",
  "order_status",
  "human_requested",
  "suspected_manipulation",
  "unsupported_language",
  "repeated_clarification_failed",
  "out_of_scope",
] as const;
export const CONFLICT_FIELDS = [
  "product",
  "variant",
  "quantity",
  "customer_name",
  "customer_phone",
  "zone",
  "area",
  "address",
  "payment_method",
] as const;

const nullable = (schema: Record<string, unknown>) => ({ anyOf: [schema, { type: "null" }] });
const str = { type: "string" };
const segments = {
  type: "array",
  items: {
    anyOf: [
      { type: "object", properties: { text: str }, required: ["text"], additionalProperties: false },
      {
        type: "object",
        properties: { fact: { type: "string", enum: FACTS }, ref: str },
        required: ["fact", "ref"],
        additionalProperties: false,
      },
    ],
  },
};

/** JSON schema sent as output_config.format (supported subset: no length or numeric limits). */
export const OUTPUT_SCHEMA: Record<string, unknown> = {
  type: "object",
  properties: {
    intent: { type: "string", enum: INTENTS },
    reply_language: { type: "string", enum: ["ckb", "ar", "en"] },
    reply: segments,
    clarification: segments,
    extraction: nullable({
      type: "object",
      properties: {
        customer_name: nullable({
          type: "object",
          properties: { value: str, basis: { type: "string", enum: ["stated", "inferred"] } },
          required: ["value", "basis"],
          additionalProperties: false,
        }),
        phone: nullable({
          type: "object",
          properties: { token: str },
          required: ["token"],
          additionalProperties: false,
        }),
        phone2: nullable({
          type: "object",
          properties: { token: str },
          required: ["token"],
          additionalProperties: false,
        }),
        zone_id: nullable(str),
        city_text: nullable(str),
        area: nullable(str),
        landmark: nullable(str),
        address_details: nullable(str),
        payment_method: nullable({ type: "string", enum: ["cod", "other"] }),
        customer_note: nullable(str),
        lines: {
          type: "array",
          items: {
            type: "object",
            properties: {
              candidate_variant_ids: { type: "array", items: str },
              customer_text: str,
              quantity: nullable({ type: "integer" }),
              quantity_basis: { type: "string", enum: ["stated", "inferred"] },
            },
            required: ["candidate_variant_ids", "customer_text", "quantity", "quantity_basis"],
            additionalProperties: false,
          },
        },
        conflicts: {
          type: "array",
          items: {
            type: "object",
            properties: { field: { type: "string", enum: CONFLICT_FIELDS }, note: str },
            required: ["field", "note"],
            additionalProperties: false,
          },
        },
      },
      required: [
        "customer_name",
        "phone",
        "phone2",
        "zone_id",
        "city_text",
        "area",
        "landmark",
        "address_details",
        "payment_method",
        "customer_note",
        "lines",
        "conflicts",
      ],
      additionalProperties: false,
    }),
    missing_fields: { type: "array", items: { type: "string", enum: MISSING } },
    escalation: {
      type: "object",
      properties: {
        required: { type: "boolean" },
        reasons: { type: "array", items: { type: "string", enum: ESCALATIONS } },
      },
      required: ["required", "reasons"],
      additionalProperties: false,
    },
  },
  required: [
    "intent",
    "reply_language",
    "reply",
    "clarification",
    "extraction",
    "missing_fields",
    "escalation",
  ],
  additionalProperties: false,
};

type Json = null | boolean | number | string | Json[] | { [k: string]: Json };
const isObj = (v: unknown): v is Record<string, Json> =>
  typeof v === "object" && v !== null && !Array.isArray(v);
const onlyKeys = (o: Record<string, unknown>, keys: readonly string[]) =>
  Object.keys(o).every((k) => keys.includes(k));
const strMax = (v: unknown, max: number) => typeof v === "string" && [...v].length <= max;
const nullOrStrMax = (v: unknown, max: number) => v === null || v === undefined || strMax(v, max);
const oneOf = (v: unknown, list: readonly string[]) => typeof v === "string" && list.includes(v);

function segmentErrors(value: unknown, path: string): string[] {
  if (!Array.isArray(value)) return [path];
  if (value.length > 40) return [path];
  const errors: string[] = [];
  value.forEach((s, i) => {
    if (!isObj(s)) errors.push(`${path}.${i}`);
    else if ("text" in s) {
      if (!onlyKeys(s, ["text"]) || !strMax(s.text, 1500)) errors.push(`${path}.${i}`);
    } else if ("fact" in s) {
      if (!onlyKeys(s, ["fact", "ref"]) || !oneOf(s.fact, FACTS) || !strMax(s.ref, 64)) {
        errors.push(`${path}.${i}`);
      }
    } else errors.push(`${path}.${i}`);
  });
  return errors;
}

/** Paths of every violation; an empty list means the output may be handed to the database. */
export function outputErrors(out: unknown): string[] {
  if (!isObj(out)) return ["output"];
  const errors: string[] = [];
  const top = [
    "intent",
    "reply_language",
    "reply",
    "clarification",
    "extraction",
    "missing_fields",
    "escalation",
  ];
  for (const k of Object.keys(out)) if (!top.includes(k)) errors.push(k);
  if (!oneOf(out.intent, INTENTS)) errors.push("intent");
  if (!oneOf(out.reply_language, ["ckb", "ar", "en"])) errors.push("reply_language");
  errors.push(
    ...segmentErrors(out.reply, "reply"),
    ...segmentErrors(out.clarification ?? [], "clarification"),
  );
  if (!Array.isArray(out.missing_fields) || !out.missing_fields.every((m) => oneOf(m, MISSING))) {
    errors.push("missing_fields");
  }
  const esc = out.escalation;
  if (
    !isObj(esc) || !onlyKeys(esc, ["required", "reasons"]) || typeof esc.required !== "boolean" ||
    !Array.isArray(esc.reasons) || !esc.reasons.every((r) => oneOf(r, ESCALATIONS))
  ) errors.push("escalation");

  const x = out.extraction;
  if (x === null || x === undefined) return errors;
  if (!isObj(x)) return [...errors, "extraction"];
  const keys = [
    "customer_name",
    "phone",
    "phone2",
    "zone_id",
    "city_text",
    "area",
    "landmark",
    "address_details",
    "payment_method",
    "customer_note",
    "lines",
    "conflicts",
  ];
  for (const k of Object.keys(x)) if (!keys.includes(k)) errors.push(`extraction.${k}`);
  const name = x.customer_name;
  if (
    !(name === null || name === undefined ||
      (isObj(name) && onlyKeys(name, ["value", "basis"]) && strMax(name.value, 200) &&
        oneOf(name.basis, ["stated", "inferred"])))
  ) errors.push("extraction.customer_name");
  for (const k of ["phone", "phone2"]) {
    const p = x[k];
    if (
      !(p === null || p === undefined || (isObj(p) && onlyKeys(p, ["token"]) && typeof p.token === "string" &&
        /^PHONE_[0-9]{1,2}$/.test(p.token)))
    ) errors.push(`extraction.${k}`);
  }
  if (
    !nullOrStrMax(x.zone_id, 64) || !nullOrStrMax(x.city_text, 200) || !nullOrStrMax(x.area, 200) ||
    !nullOrStrMax(x.landmark, 300) || !nullOrStrMax(x.address_details, 600) ||
    !nullOrStrMax(x.customer_note, 800) ||
    !(x.payment_method === null || x.payment_method === undefined ||
      oneOf(x.payment_method, ["cod", "other"]))
  ) errors.push("extraction.fields");
  const lines = x.lines ?? [];
  if (!Array.isArray(lines) || lines.length > 20) errors.push("extraction.lines");
  else {
    lines.forEach((l, i) => {
      const ok = isObj(l) &&
        onlyKeys(l, ["candidate_variant_ids", "customer_text", "quantity", "quantity_basis"]) &&
        Array.isArray(l.candidate_variant_ids) && l.candidate_variant_ids.length <= 10 &&
        l.candidate_variant_ids.every((c) => strMax(c, 64)) && strMax(l.customer_text, 400) &&
        (l.quantity === null || l.quantity === undefined || typeof l.quantity === "number") &&
        oneOf(l.quantity_basis, ["stated", "inferred"]);
      if (!ok) errors.push(`extraction.lines.${i}`);
    });
  }
  const conflicts = x.conflicts ?? [];
  if (
    !Array.isArray(conflicts) ||
    !conflicts.every((c) =>
      isObj(c) && onlyKeys(c, ["field", "note"]) && oneOf(c.field, CONFLICT_FIELDS) &&
      nullOrStrMax(c.note, 300)
    )
  ) errors.push("extraction.conflicts");
  return errors;
}
