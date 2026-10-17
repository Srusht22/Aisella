#!/usr/bin/env python3
"""AI execution role through the real HTTP stack (Kong -> PostgREST -> Postgres), LOCAL only.

PostgREST switches to the database role named in a verified JWT. These checks prove that a token
for `aisellia_ai` reaches exactly one function, that the store comes from the owner's grant, and
that forged, anonymous and end-user tokens cannot use the AI path.

Tokens are minted with the LOCAL stack's JWT secret (as a server-side AI worker would hold its
own credential); the script refuses any non-local URL. Standard library only.

  SUPABASE_TEST_URL=... SUPABASE_TEST_PUBLISHABLE_KEY=... SUPABASE_TEST_JWT_SECRET=... \
  SUPABASE_DB_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres \
  python3 -I supabase/tests/api/ai_role_api_test.py
"""
import base64
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

URL = os.environ.get("SUPABASE_TEST_URL", "")
KEY = os.environ.get("SUPABASE_TEST_PUBLISHABLE_KEY", "")
SECRET = os.environ.get("SUPABASE_TEST_JWT_SECRET", "")
DB = os.environ.get("SUPABASE_DB_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

for name, value in (("SUPABASE_TEST_URL", URL), ("SUPABASE_DB_URL", DB)):
    host = urllib.parse.urlparse(value).hostname
    if host not in ("127.0.0.1", "localhost"):
        sys.exit(f"Refusing to run against a non-local {name}.")
if not (KEY and SECRET):
    sys.exit("Set SUPABASE_TEST_PUBLISHABLE_KEY and SUPABASE_TEST_JWT_SECRET (local stack).")

failures = []
passed = 0


def check(cond, label):
    global passed
    if cond:
        passed += 1
        print(f"ok - {label}")
    else:
        failures.append(label)
        print(f"not ok - {label}")


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt(claims: dict, secret: str = SECRET) -> str:
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = b64(json.dumps({**claims, "exp": int(time.time()) + 600}).encode())
    sig = hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
    return f"{header}.{payload}.{b64(sig)}"


def rpc(fn: str, params: dict, token: str | None):
    headers = {"apikey": KEY, "Content-Type": "application/json", "Content-Profile": "api",
               "Accept-Profile": "api"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{URL}/rest/v1/rpc/{fn}", data=json.dumps(params).encode(),
                                 headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            return res.status, json.loads(res.read() or b"null")
    except urllib.error.HTTPError as e:
        body = e.read()
        try:
            return e.code, json.loads(body or b"null")
        except ValueError:
            return e.code, body.decode(errors="replace")


def get(path: str, token: str | None):
    headers = {"apikey": KEY, "Accept-Profile": "api"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(f"{URL}{path}", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            return res.status, res.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def sql(statement: str) -> str:
    return subprocess.run(["psql", DB, "-X", "-q", "-t", "-A", "-c", statement],
                          check=True, capture_output=True, text=True).stdout.strip()


def new_seller(tag: str):
    """A confirmed user (created directly, as the pgTAP helpers do) with a store, a product and a grant."""
    user = str(uuid.uuid4())
    sql("insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, raw_user_meta_data) "
        f"values ('{user}', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', "
        f"'ai-api-{tag}-{user[:8]}@example.test', now(), '{{\"terms_version\": \"2026-10\"}}')")
    token = jwt({"sub": user, "role": "authenticated", "aud": "authenticated"})
    _, store = rpc("create_store", {"p_name": f"Shop {tag}", "p_contact_phone": "+9647501234567", "p_currency": "IQD",
                                    "p_reply_locale": "ckb", "p_business_city": "Erbil",
                                    "p_idempotency_key": str(uuid.uuid4())}, token)
    store_id = store["data"]["id"]
    _, zone = rpc("upsert_zone", {"p_store_id": store_id, "p_zone_id": None, "p_expected_version": None,
                                  "p_name": "Erbil", "p_fee": 5000, "p_time_text": None,
                                  "p_idempotency_key": str(uuid.uuid4())}, token)
    _, product = rpc("upsert_product", {"p_store_id": store_id, "p_product_id": str(uuid.uuid4()),
                                        "p_expected_version": None, "p_idempotency_key": str(uuid.uuid4()),
                                        "p_product": {"name": "Beige Abaya", "base_price": 35000, "track_stock": True,
                                                      "status": "active", "option_types": [], "images": [],
                                                      "variants": [{"option_values": [], "initial_stock": 4}]}}, token)
    _, grant = rpc("create_ai_draft_grant", {"p_store_id": store_id, "p_ai_ref": None, "p_label": "test",
                                             "p_valid_hours": 1}, token)
    return {"user": user, "token": token, "store": store_id, "zone": zone["data"]["id"],
            "variant": product["data"]["variants"][0]["id"], "grant": grant["data"]["secret"]}


def draft(seller, ref="conv-1", qty=2):
    return {"customer_name": "Nzar Ahmad", "customer_phone": "+9647501112233", "zone_id": seller["zone"],
            "area": "Ankawa", "payment_method": "cod", "lines": [{"variant_id": seller["variant"], "quantity": qty}]}


def ai_upsert(token, grant, ref, order):
    return rpc("ai_upsert_draft", {"p_grant": grant, "p_ref": ref, "p_order": order,
                                   "p_idempotency_key": str(uuid.uuid4())}, token)


a = new_seller("a")
b = new_seller("b")
check(a["grant"].startswith("aig_"), "the owner obtains a grant through the API")
ai = jwt({"role": "aisellia_ai"})

status, body = ai_upsert(ai, a["grant"], "conv-1", draft(a))
check(status == 200 and body["ok"] and body["data"]["status"] == "pending_approval",
      "an AI token creates a draft through PostgREST")
check(body["data"]["total"] == 75000, "the server computed the total (2 x 35,000 + 5,000)")
order_id = body["data"]["order_id"]

status, _ = rpc("approve_order", {"p_store_id": a["store"], "p_order_id": order_id, "p_expected_version": 1,
                                  "p_price_choices": {}, "p_idempotency_key": str(uuid.uuid4())}, ai)
check(status in (401, 403), f"the AI token cannot approve (HTTP {status})")
for fn, params in (("cancel_order", {"p_store_id": a["store"], "p_order_id": order_id, "p_expected_version": 1,
                                     "p_reason": "duplicate", "p_note": None, "p_idempotency_key": str(uuid.uuid4())}),
                   ("get_order", {"p_store_id": a["store"], "p_order_id": order_id}),
                   ("create_order", {"p_store_id": a["store"], "p_order": {}, "p_idempotency_key": str(uuid.uuid4())}),
                   ("create_ai_draft_grant", {"p_store_id": a["store"], "p_ai_ref": None, "p_label": None,
                                              "p_valid_hours": 1})):
    status, _ = rpc(fn, params, ai)
    check(status in (401, 403), f"the AI token cannot call {fn} (HTTP {status})")
status, text = get("/rest/v1/stores?select=id", ai)
check(status in (401, 403), f"the AI token cannot read the stores view (HTTP {status})")
status, text = get(f"/storage/v1/object/list/store-media", ai)
check(status != 200 or text.strip() in ("[]", ""), f"the AI token gets nothing from storage (HTTP {status})")

status, body = ai_upsert(ai, b["grant"], "conv-1", {"lines": [{"variant_id": a["variant"], "quantity": 1}]})
check(body.get("error", {}).get("details", {}).get("fields", {}).get("lines.0.variant_id") == "unknown",
      "with seller B's grant, seller A's product reads as unknown")
check(sql(f"select customer_name from app.orders where id = '{order_id}'") == "Nzar Ahmad",
      "seller A's order is unchanged")

status, body = ai_upsert(a["token"], a["grant"], "conv-2", draft(a))
check(status in (401, 403), f"the store owner's own token cannot use the AI path (HTTP {status})")
status, body = ai_upsert(None, a["grant"], "conv-2", draft(a))
check(status in (401, 403), f"an anonymous caller cannot use the AI path (HTTP {status})")
forged = jwt({"role": "aisellia_ai"}, secret="not-the-project-secret-but-long-enough-0000")
status, body = ai_upsert(forged, a["grant"], "conv-2", draft(a))
check(status == 401, f"a token not signed by the project is rejected (HTTP {status})")
service = jwt({"role": "service_role"})
status, body = ai_upsert(service, a["grant"], "conv-2", draft(a))
check(status in (401, 403), f"a service_role token cannot use the AI path either (HTTP {status})")
check(sql(f"select count(*) from app.orders where store_id = '{a['store']}'") == "1",
      "none of the refused calls created an order")

print(f"1..{passed + len(failures)}")
if failures:
    print(f"# {len(failures)} failed")
    sys.exit(1)
print("All AI role API checks passed.")
