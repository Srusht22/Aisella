# Aisellia — Phase 8: the AI sales assistant

**Status:** Implemented and tested locally. **Waiting for owner approval. Phase 9 has not started.**

**Baselines:**
- [Phase 1 product spec](../../product/phase-1-product-specification.md): §8 AI behaviour, US-020…US-028, BR-45…BR-49;
- [Phase 3 AI architecture](../../architecture/phase-3/ai-integration-architecture.md);
- [Phase 7 doc I, security hardening](../phase-7/i-security-hardening.md). Where it and Phase 3 differ, the stronger boundary was kept (see [A §2](a-ai-architecture.md#2-where-this-differs-from-phase-3)).

A seller can now:
- paste a customer's conversation from Instagram, WhatsApp or another app, or open a sandbox test;
- ask the AI assistant for a **suggested reply**. Prices, fees, availability, delivery times and policies in that reply are **rendered by the database from the store's current records**, never written by the model;
- see which store facts the reply used, what is still missing, and why the assistant handed the conversation to the seller ("Needs you");
- copy the reply (optionally edited), send it themselves, and mark it as sent. Aisellia never sends a message;
- get an **AI draft order**. The AI creates or updates it from the conversation, and the seller reviews and **approves it explicitly** on the existing order screen. The AI can never approve;
- switch the assistant off, pause it per conversation, and write the policies it may quote.

**Not done in this phase:**
- no live messaging channel;
- no automatic sending;
- no deployment;
- no customer has been contacted.

**The real model has not been called in this environment:** no Anthropic API key was available (see [G](g-evaluation-report.md)).

| # | Document | Contents |
|---|---|---|
| A | [AI architecture](a-ai-architecture.md) | Components, flow, provider, configuration, deployment steps |
| B | [Tool and function contracts](b-tool-contracts.md) | Every AI-related operation: inputs, authorization, outputs |
| C | [Business data retrieval](c-business-data-retrieval.md) | What context the model gets, how it is scoped, freshness, missing data |
| D | [Order-draft integration](d-order-draft-integration.md) | How AI drafts use Phase 7, duplicates, seller edits, the approval gate |
| E | [Privacy and security](e-privacy-security.md) | Data sent to the provider, secrets, access control, injection defences |
| F | [Cost and reliability](f-cost-reliability.md) | Usage metrics, quotas, timeouts, retries, failure handling |
| G | [Evaluation report](g-evaluation-report.md) | Scenarios, languages, what ran, what could not run |
| H | [Completion report](h-phase-8-completion-report.md) | Features, files, migrations, tests, commits, risks, next steps |
