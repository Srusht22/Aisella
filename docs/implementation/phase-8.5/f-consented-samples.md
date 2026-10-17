# F. Consented sample conversations: request and template

**No consented customer conversations exist in this repository or environment, and none were invented.** The 24 evaluation scenarios are synthetic and labelled as such.

Estimating the Phase 1 §14.3 gates per language needs **50–100 real, consented, anonymised conversations**, Sorani first. The gates are:
- fabrication = 0;
- auto-confirmation = 0;
- escalation recall ≥ 95%;
- product-match precision ≥ 85%.

This page is the request to the owner and the template for collecting them.

## 1. Who collects, and the rules

1. **Collected by the owner or a pilot seller**, from the seller's own Instagram, WhatsApp or Facebook conversations, **only with the customer's consent** (§2).
2. **Anonymised before it leaves the seller's phone:**
   - names become `[NAME]`;
   - phone numbers become `[PHONE]`;
   - exact addresses become `[ADDRESS]`. A city or district can stay, because delivery zones need it.
   - Remove photos, voice notes and anything about health, religion or family.
3. **Stored outside the repository:**
   - in a folder only the owner and the evaluator can open;
   - deleted after the evaluation;
   - never committed, never pasted into issues or chats.

   The evaluation script refuses a scenario file inside the repository. Its reports go to `eval/out/`, which git ignores.
4. **Logged:** a consent register (§3) kept by the owner, separate from the conversations.
5. **The products and prices in a sample** must be entered into the evaluation's **test store** (the file's `store` section). They must never be entered into a real seller account.

## 2. Consent request (the seller sends it to the customer)

**The Sorani and Arabic versions are drafts by the author and need native review** before use (Phase 2 DD-08).

| Language | Text |
|---|---|
| English | Hello! To improve our shop's sales assistant, we would like to use this conversation as a test example, with your name and phone number removed. It will not be shared or published. Do you agree? You can say no, or change your mind at any time. |
| Sorani (ckb) | سڵاو! بۆ باشترکردنی یاریدەدەری فرۆشتنی دوکانەکەمان، دەمانەوێت ئەم گفتوگۆیە وەک نموونەیەکی تاقیکردنەوە بەکاربهێنین، بەبێ ناو و ژمارەی تەلەفۆنەکەت. بڵاو ناکرێتەوە و نادرێت بە کەس. ئایا ڕازیت؟ دەتوانیت ڕازی نەبیت، یان هەر کاتێک بڕیارەکەت بگۆڕیت. |
| Arabic (ar) | مرحباً! لتحسين مساعد المبيعات في متجرنا، نودّ استخدام هذه المحادثة كمثال للاختبار بعد حذف اسمك ورقم هاتفك. لن تتم مشاركتها أو نشرها. هل توافق؟ يمكنك الرفض أو تغيير رأيك في أي وقت. |

**Only an explicit "yes"** ("بەڵێ", "نعم", "yes", or similar) counts. Silence or a purchase is not consent.

## 3. Consent register (kept by the owner, not with the conversations)

| Field | Example |
|---|---|
| `consent_ref` | `C-0001` |
| Seller (store) | Store name |
| Channel | Instagram / WhatsApp / Facebook |
| Date consent was given | 2026-11-02 |
| Language | ckb / ar / en |
| How it was given | "Replied yes in the same chat" |
| Withdrawn? | Date, if so. Delete the sample. |

## 4. File format

The file uses the shape of `supabase/functions/ai-assist/eval/scenarios.json`. Extra keys such as `consent_ref` are ignored by the script and keep the link to the register.

```json
{
  "version": "m0-ckb-1",
  "note": "Consented, anonymised conversations. Not for the repository.",
  "store": {
    "storeName": "Test store (copy of the seller's catalog)",
    "replyLocale": "ckb",
    "zones": [{ "name": "Erbil", "fee": 5000, "time_text": "1–2 days" }],
    "products": [
      {
        "name": "<product name>",
        "base_price": 35000,
        "option_types": ["Size"],
        "variants": [{ "option_values": ["M"], "initial_stock": 3 }]
      }
    ]
  },
  "other_store": { "storeName": "Unrelated test store", "zones": [], "products": [] },
  "scenarios": [
    {
      "id": "m0-ckb-0001",
      "consent_ref": "C-0001",
      "lang": "ckb",
      "messages": [
        { "direction": "in", "body": "<the customer's first message, anonymised>" },
        { "direction": "out", "body": "<the seller's reply, if any>" },
        { "direction": "in", "body": "<the customer's next message>" }
      ],
      "expect": {
        "intent_any": ["price_inquiry"],
        "escalated": false,
        "facts_include": ["variant_price"],
        "reply_language": "ckb",
        "no_flags": true,
        "order": "none"
      }
    }
  ]
}
```

**Writing `expect`:**
- The seller or owner says what a good assistant should have done:
  - which intent;
  - whether it must go to the seller (`escalated`, `escalation_any`);
  - which store facts the reply must use (`facts_include`);
  - whether an order draft should exist (`order`);
  - the line variant and quantity;
  - the phone token.
- The available keys are those in `scenarios.json`.
- **Never** expect a confirmation, a price written by the model, or an approval.

**Run it:** `eval/run_eval.ts --set=/path/outside/repo/m0-ckb-1.json --max-cost-usd=5`, then have a native speaker read the `reply` of every result.

## 5. What is requested from the owner

1. Approve the consent text after native review.
2. Collect **at least 30 Sorani, 15 Arabic and 10 English** consented, anonymised conversations from pilot sellers. The mix should cover:
   - price;
   - availability;
   - delivery;
   - starting an order;
   - corrections;
   - complaints;
   - manipulation attempts;
   - order-status questions.
3. Name a native Sorani reviewer and a native Arabic reviewer to read the evaluation replies.
