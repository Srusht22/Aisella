-- Phase 8.5: "delete this customer" reaches the seller's free-text notes, status history and audit;
-- and the retention jobs for AI outputs and message bodies do what they promise.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(42);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
create function pg_temp.ver(p text) returns integer language sql security definer as $$
  select version from app.orders where id = pg_temp.id(p)
$$;
create function pg_temp.notes(p text) returns text language sql security definer as $$
  select concat_ws(' | ', internal_note, closed_note, courier_note, payment_note) from app.orders where id = pg_temp.id(p)
$$;

-- ---- 1. The redaction function -------------------------------------------------------------------------------
create temp table phone_cases (txt text, want text);
insert into phone_cases values
  ('call 07501112233 now', 'call [redacted] now'),
  ('call 0750 111 2233 now', 'call [redacted] now'),
  ('call +964 750 111 2233', 'call [redacted]'),
  ('call 00964-750-111-2233', 'call [redacted]'),
  ('call 9647501112233', 'call [redacted]'),
  ('call 750.111.2233', 'call [redacted]'),
  ('زەنگ بۆ ٠٧٥٠١١١٢٢٣٣ بکە', 'زەنگ بۆ [redacted] بکە'),
  ('اتصل ۰۷۵۰ ۱۱۱ ۲۲۳۳', 'اتصل [redacted]'),
  ('another number 07501112234', 'another number 07501112234'),
  ('a longer code 075011122339', 'a longer code 075011122339');
select is(app.redact_contact_text(txt, null, array['+9647501112233']), want, format('phone redaction: %s', txt))
  from phone_cases order by txt;
select is(app.redact_contact_text('Nzar Ahmad paid; nzar will call; ask Ahmad''s brother', 'Nzar Ahmad', null),
          '[redacted] paid; [redacted] will call; ask [redacted]''s brother', 'the name and each of its words are redacted, any case');
select is(app.redact_contact_text('Ask Alice, not Ali', 'Ali Karim', null), 'Ask Alice, not [redacted]',
          'a Latin name word must stand alone ("Alice" stays)');
select is(app.redact_contact_text('نزارەکە زەنگی لێدا', 'نزار', null), '[redacted]ەکە زەنگی لێدا',
          'a Sorani name is redacted even with a suffix attached');
select is(app.redact_contact_text('Leave at the gate', 'Al', null), 'Leave at the gate', 'names shorter than 3 letters are not used');
select is(app.redact_contact_json('{"a": "Nzar 0750 111 2233", "b": [{"c": "Nzar"}], "n": 5}', 'Nzar', array['+9647501112233']),
          '{"a": "[redacted] [redacted]", "b": [{"c": "[redacted]"}], "n": 5}'::jsonb, 'JSON values are redacted at any depth');

-- ---- 2. Orders with notes that repeat the customer ---------------------------------------------------------
insert into ids values ('a', pg_temp.new_user('notes-a@example.test'));
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select api.update_store(pg_temp.id('store_a'), 1, '{"other_payment_enabled": true}', gen_random_uuid());
insert into ids select 'zone_a', (api.upsert_zone(pg_temp.id('store_a'), null, null, 'Erbil', 5000, null, gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v_a', (api.upsert_product(pg_temp.id('store_a'), gen_random_uuid(), null,
  '{"name": "Abaya A", "base_price": 35000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 20}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
create function pg_temp.new_order(p_key text, p_name text, p_phone text, p_note text, p_payment text default 'cod',
                                  p_payment_note text default null) returns void language plpgsql as $$
begin
  insert into ids select p_key, (api.create_order(pg_temp.id('store_a'), jsonb_strip_nulls(jsonb_build_object(
    'customer_name', p_name, 'customer_phone', p_phone, 'zone_id', pg_temp.id('zone_a'), 'area', 'Ankawa',
    'payment_method', p_payment, 'payment_note', p_payment_note, 'internal_note', p_note,
    'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_a'), 'quantity', 1)))), gen_random_uuid()) #>> '{data,id}')::uuid;
end $$;
create function pg_temp.go(p_key text, p_to text, p_payload jsonb default '{}') returns jsonb language sql as $$
  select api.transition_order(pg_temp.id('store_a'), pg_temp.id(p_key), pg_temp.ver(p_key), p_to, p_payload, gen_random_uuid())
$$;

-- o1: delivered; internal, payment and courier notes name the customer.
select pg_temp.new_order('o1', 'Nzar Ahmad', '+9647501112233', 'Nzar prefers evenings, alt 0750-111-2233',
                         'other', 'Transfer from 07501112233');
select api.approve_order(pg_temp.id('store_a'), pg_temp.id('o1'), pg_temp.ver('o1'), '{}', gen_random_uuid());
select pg_temp.go('o1', 'dispatched', '{"courier_note": "call ٠٧٥٠ ١١١ ٢٢٣٣ at the gate"}');
select pg_temp.go('o1', 'delivered');
-- o2: rejected with a closing note that names the customer (the note goes into the status history).
select pg_temp.new_order('o2', 'Nzar Ahmad', '+9647501112233', 'second try');
select api.reject_draft(pg_temp.id('store_a'), pg_temp.id('o2'), pg_temp.ver('o2'), 'other',
                        'Nzar Ahmad cancelled by phone +964 750 111 2233', gen_random_uuid());
-- o3: a Sorani note.
select pg_temp.new_order('o3', 'نزار', '+9647501112233', 'نزارەکە زەنگی لێدا');
select api.reject_draft(pg_temp.id('store_a'), pg_temp.id('o3'), pg_temp.ver('o3'), 'duplicate', null, gen_random_uuid());
-- p1: his sister's order, anonymised before; her note still carries his number.
select pg_temp.new_order('p1', 'Shno Ali', '+9647504443322', 'the sister; her brother 07501112233 pays');
select api.reject_draft(pg_temp.id('store_a'), pg_temp.id('p1'), pg_temp.ver('p1'), 'duplicate', null, gen_random_uuid());
select api.anonymize_customer(pg_temp.id('store_a'), '+9647504443322', gen_random_uuid());
-- live: an order in progress for someone else that mentions him (not his order: untouched).
select pg_temp.new_order('live', 'Rezan Omar', '+9647701231234', 'friend of 07501112233');

select pg_temp.act_as_admin();
select ok(pg_temp.notes('o1') like '%Nzar%' and pg_temp.notes('o1') like '%٠٧٥٠ ١١١ ٢٢٣٣%', 'setup: notes repeat the name and number');
select is(pg_temp.notes('p1'), 'the sister; her brother 07501112233 pays',
          'setup: anonymising Shno left the other number in her note (the gap being fixed)');

select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'anon', api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', gen_random_uuid());
select is((pg_temp.r('anon') -> 'data') - 'order_ids', '{"anonymized": 3, "skipped_in_progress": 0, "notes_redacted": 4}'::jsonb,
          'three orders are anonymised; notes change on those three and on the earlier p1');

select pg_temp.act_as_admin();
select is(pg_temp.notes('o1'), '[redacted] prefers evenings, alt [redacted] | call [redacted] at the gate | Transfer from [redacted]',
          'internal, courier and payment notes keep their content but lose the name and number');
select is(pg_temp.notes('o2'), 'second try | [redacted] cancelled by phone [redacted]', 'the closing note too');
select is(pg_temp.notes('o3'), '[redacted]ەکە زەنگی لێدا', 'a Sorani note too');
select is(pg_temp.notes('p1'), 'the sister; her brother [redacted] pays',
          'an order anonymised earlier loses this number from its note');
select is(pg_temp.notes('live'), 'friend of 07501112233', 'an order in progress of another customer is untouched');
select is((select note from app.order_status_events where order_id = pg_temp.id('o2') and to_status = 'rejected'),
          '[redacted] cancelled by phone [redacted]', 'the status history note is redacted');
select is((select note from app.order_status_events where order_id = pg_temp.id('o1') and to_status = 'dispatched'),
          (select courier_note from app.orders where id = pg_temp.id('o1')), '… including a courier note recorded with a transition');
select is((select count(*)::integer from app.order_status_events where order_id in (pg_temp.id('o1'), pg_temp.id('o2'))), 6,
          'no status event is removed');
select ok(not exists (select 1 from app.audit_events
                       where entity_id in (pg_temp.id('o1'), pg_temp.id('o2'), pg_temp.id('o3'), pg_temp.id('p1'))
                         and (coalesce(before::text, '') || coalesce(after::text, '')) ~ '(Nzar|نزار|2233|٢٢٣٣)'),
          'no audit row of those orders still holds the name or the number, inside notes or not');
select ok(exists (select 1 from app.audit_events where entity_id = pg_temp.id('o1') and after ->> 'internal_note' like '%prefers evenings%'),
          'audit notes keep their non-identifying content');
select is((select after ->> 'notes_redacted' from app.audit_events where store_id = pg_temp.id('store_a') and action = 'customer.anonymize'
            order by id desc limit 1), '4', 'the anonymisation audit counts the notes, without their text');

-- Status history stays append-only outside the redaction.
select throws_ok(format('update app.order_status_events set note = %L where order_id = %L', 'x', pg_temp.id('o2')), 'AS002', null,
                 'a status note cannot be edited outside anonymisation');
select set_config('aisellia.redact', 'on', true);
select throws_ok(format('update app.order_status_events set to_status = %L where order_id = %L', 'delivered', pg_temp.id('o2')), 'AS002', null,
                 'even under the redaction flag, only the note may change');
select set_config('aisellia.redact', 'off', true);
select throws_ok(format('delete from app.order_status_events where order_id = %L', pg_temp.id('o2')), 'AS002', null,
                 'status history cannot be deleted');

-- ---- 3. Retention jobs: AI outputs (90 days) and message bodies (12 months) --------------------------------
grant aisellia_ai_worker to postgres with set true, inherit false;  -- rolled back
grant usage on schema extensions to aisellia_ai_worker;              -- rolled back
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'c_old', (api.create_conversation(pg_temp.id('store_a'), 'instagram', null,
  '[{"direction": "in", "body": "old question about the abaya"}]', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'c_new', (api.create_conversation(pg_temp.id('store_a'), 'instagram', null,
  '[{"direction": "in", "body": "new question about the abaya"}]', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'run_old', (api.request_ai_assist(pg_temp.id('store_a'), pg_temp.id('c_old'), 'reply', gen_random_uuid())
                                   #>> '{data,run_id}')::uuid;
insert into ids select 'run_new', (api.request_ai_assist(pg_temp.id('store_a'), pg_temp.id('c_new'), 'reply', gen_random_uuid())
                                   #>> '{data,run_id}')::uuid;
reset role;
set local role aisellia_ai_worker;
select api.ai_claim_run(pg_temp.id('run_old')), api.ai_claim_run(pg_temp.id('run_new'));
select api.ai_complete_run(r, '{"intent": "greeting", "reply_language": "en", "reply": [{"text": "Hello"}], "clarification": [],
                                "extraction": null, "missing_fields": [], "escalation": {"required": false, "reasons": []}}',
                           '{"model": "claude-opus-5-5"}')
  from unnest(array[pg_temp.id('run_old'), pg_temp.id('run_new')]) r;
reset role;
update app.ai_runs set finished_at = now() - interval '91 days' where id = pg_temp.id('run_old');
update app.conversations set last_activity_at = now() - interval '366 days' where id = pg_temp.id('c_old');

select is(internal.purge_ai_run_outputs(), 1, 'the AI output job clears the run older than 90 days');
select is((select row(output_json is null, pii_map is null, status)::text
             from app.ai_runs where id = pg_temp.id('run_old')), row(true, true, 'succeeded')::text,
          '… its output goes, its status and metrics stay');
select ok((select output_json is not null from app.ai_runs where id = pg_temp.id('run_new')), '… a recent run keeps its output');
select is(internal.purge_message_bodies(), 1, 'the message job clears bodies of conversations idle for over 12 months');
select is((select row(body is null, body_purged_at is not null)::text from app.messages where conversation_id = pg_temp.id('c_old')),
          row(true, true)::text, '… the message row stays, marked purged');
select is((select text_rendered from app.reply_suggestions where conversation_id = pg_temp.id('c_old')), null, '… the suggestion text goes');
select is((select body from app.messages where conversation_id = pg_temp.id('c_new')), 'new question about the abaya',
          '… a recent conversation keeps its text');
select is(internal.purge_message_bodies(interval '1 hour'), -1, 'a retention under one day is refused');
select is((select status from app.job_runs where job = 'purge_message_bodies' order by id desc limit 1), 'failed',
          '… and recorded as failed');
select ok(exists (select 1 from internal.job_health() where job = 'purge_ai_run_outputs' and not stale), 'job health reports the AI output job');

select * from finish();
rollback;
