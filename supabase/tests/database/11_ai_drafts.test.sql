-- AI-created drafts: the privilege boundary, store binding, validation, seller edits and quotas
-- (docs/implementation/phase-7/f-integration-contract.md §1; Phase 8 hardening milestone).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(69);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
create temp table secrets (k text primary key, v text);
grant all on ids, res, secrets to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
create function pg_temp.sec(p text) returns text language sql as $$ select v from secrets where k = p $$;
create function pg_temp.save(p_key text, p_value jsonb) returns jsonb language sql as $$
  insert into res values (p_key, p_value) on conflict (k) do update set v = excluded.v returning v
$$;

-- Test scaffolding only (rolled back with the test): pgTAP lives in `extensions`, which the AI role
-- cannot enter. 01_catalog_guards checks the real schema access of aisellia_ai.
grant usage on schema extensions to aisellia_ai;

-- The AI as PostgREST runs it: database role aisellia_ai, JWT role claim aisellia_ai, no user.
create function pg_temp.act_as_ai() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role": "aisellia_ai"}', true);
  execute 'set local role aisellia_ai';
end $$;
create function pg_temp.ai(p_grant text, p_ref text, p_order jsonb, p_key uuid default gen_random_uuid())
returns jsonb language sql as $$ select api.ai_upsert_draft(p_grant, p_ref, p_order, p_key) $$;

insert into ids values ('a', pg_temp.new_user('ai-a@example.test')), ('b', pg_temp.new_user('ai-b@example.test')),
  ('abaya', gen_random_uuid()), ('scarf', gen_random_uuid()), ('mug_b', gen_random_uuid()), ('k1', gen_random_uuid());

-- Seller A: zone, products, two grants (one limited to conversation conv-2).
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'zone', (api.upsert_zone(pg_temp.id('store_a'), null, null, 'Erbil', 5000, null, gen_random_uuid()) #>> '{data,id}')::uuid;
insert into res select 'abaya', api.upsert_product(pg_temp.id('store_a'), pg_temp.id('abaya'), null,
  '{"name": "Beige Abaya", "base_price": 35000, "track_stock": true, "status": "active", "option_types": ["Size"],
    "variants": [{"option_values": ["S"], "initial_stock": 5}, {"option_values": ["M"], "initial_stock": 4},
                 {"option_values": ["L"], "status": "archived"}], "images": []}', gen_random_uuid());
insert into ids select 'v_' || (x ->> 'label'), (x ->> 'id')::uuid from jsonb_array_elements(pg_temp.r('abaya') #> '{data,variants}') x;
insert into ids select 'v_scarf', (api.upsert_product(pg_temp.id('store_a'), pg_temp.id('scarf'), null,
  '{"name": "Old scarf", "base_price": 1000, "track_stock": true, "status": "inactive", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 3}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;

insert into res select 'g', api.create_ai_draft_grant(pg_temp.id('store_a'), null, 'Assistant', 24);
insert into secrets select 'g', pg_temp.r('g') #>> '{data,secret}';
insert into res select 'g2', api.create_ai_draft_grant(pg_temp.id('store_a'), 'conv-2', null, 1);
insert into secrets select 'g2', pg_temp.r('g2') #>> '{data,secret}';

-- Seller B: own store, product and grant.
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'ckb', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v_mug_b', (api.upsert_product(pg_temp.id('store_b'), pg_temp.id('mug_b'), null,
  '{"name": "Mug B", "base_price": 3000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 9}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
insert into secrets select 'gb', api.create_ai_draft_grant(pg_temp.id('store_b'), null, null, 24) #>> '{data,secret}';

create function pg_temp.full_order(p_lines jsonb) returns jsonb language sql as $$
  select jsonb_build_object('customer_name', 'Nzar Ahmad', 'customer_phone', '+9647501112233',
                            'zone_id', pg_temp.id('zone'), 'area', 'Ankawa', 'payment_method', 'cod', 'lines', p_lines)
$$;
create function pg_temp.line(p_variant text, p_qty integer, p_basis text default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('variant_id', pg_temp.id(p_variant), 'quantity', p_qty, 'quantity_basis', p_basis))
$$;

-- ---- Grants (owner side) -------------------------------------------------------------------
select ok(pg_temp.sec('g') ~ '^aig_[0-9a-f]{64}$', 'a grant secret is 256 bits of hex, shown once');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.ai_draft_grants where secret_hash = pg_temp.sec('g')), 0,
          'the secret itself is not stored (only its hash)');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.create_ai_draft_grant(pg_temp.id('store_a'), null, null, 1000) #>> '{error,details,fields,valid_hours}',
          'out_of_range', 'a grant lives at most 7 days');
select is(api.revoke_ai_draft_grant(pg_temp.id('store_b'), (pg_temp.r('g') #>> '{data,grant_id}')::uuid) #>> '{error,code}',
          'NOT_FOUND', 'a grant is managed only in its own store');
select is(jsonb_array_length(api.list_ai_draft_grants(pg_temp.id('store_a')) #> '{data,items}'), 2,
          'the owner lists the store''s grants');
select ok(not (api.list_ai_draft_grants(pg_temp.id('store_a'))::text ~ 'aig_'), '… without their secrets');

-- ---- The AI creates a draft ----------------------------------------------------------------------
select pg_temp.act_as_ai();
insert into res select 'c1', pg_temp.ai(pg_temp.sec('g'), 'conv-1',
  pg_temp.full_order(jsonb_build_array(pg_temp.line('v_M', 2))), pg_temp.id('k1'));
select is(pg_temp.r('c1') #>> '{data,status}', 'pending_approval',
          'the AI creates a complete order: it needs approval, it is never approved');
select is(pg_temp.r('c1') #>> '{data,created}', 'true', '… as a new order');
select is((pg_temp.r('c1') #>> '{data,lines,0,unit_price}') || ' ' || (pg_temp.r('c1') #>> '{data,delivery_fee}') || ' ' ||
          (pg_temp.r('c1') #>> '{data,total}'), '35000 5000 75000',
          'price, fee and total come from the catalog and the zone');
select ok(not (pg_temp.r('c1') -> 'data' ?| array['customer', 'internal_note', 'approved_by', 'store_id']),
          'the AI''s answer echoes no customer data, note, approver or store');
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-1', pg_temp.full_order(jsonb_build_array(pg_temp.line('v_M', 2))),
                     pg_temp.id('k1')), pg_temp.r('c1'), 'a retry with the same key replays the answer');
select pg_temp.act_as_admin();
insert into ids select 'o1', (pg_temp.r('c1') #>> '{data,order_id}')::uuid;
select is((select origin || ' ' || ai_ref || ' ' || coalesce(created_by::text, 'none') from app.orders where id = pg_temp.id('o1')),
          'ai conv-1 none', 'stored as an AI order for the conversation, created by no user');
select is((select actor_system || ' ' || to_status from app.order_status_events where order_id = pg_temp.id('o1')),
          'ai pending_approval', 'one creation event, by the AI');
select is((select count(*)::integer from app.orders where ai_ref = 'conv-1' and store_id = pg_temp.id('store_a')), 1,
          'the replay created nothing');
select is((select stock_on_hand from app.product_variants where id = pg_temp.id('v_M')), 4, 'a draft moves no stock');
select is((select approved_by from app.orders where id = pg_temp.id('o1')), null, 'nobody approved it');

-- ---- Validation: nothing the server decides can be sent -----------------------------------------
select pg_temp.act_as_ai();
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-x', pg_temp.full_order('[]') ||
            '{"status": "approved", "total": 1, "discount": 5, "delivery_fee": 0, "internal_note": "x",
              "approved_by": "me", "store_id": "x", "payment_note": "x"}') -> 'error' -> 'details' -> 'fields',
          '{"status": "unknown", "total": "unknown", "discount": "unknown", "delivery_fee": "unknown",
            "internal_note": "unknown", "approved_by": "unknown", "store_id": "unknown", "payment_note": "unknown"}'::jsonb,
          'status, totals, discount, fee, notes, approver and store are refused');
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-x', jsonb_build_object('lines', jsonb_build_array(
            pg_temp.line('v_M', 1) || '{"unit_price": 1}'))) #>> '{error,details,fields,lines.0.unit_price}',
          'unknown', 'a line price is refused');
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-x', jsonb_build_object('lines', jsonb_build_array(pg_temp.line('v_mug_b', 1))))
            #>> '{error,details,fields,lines.0.variant_id}', 'unknown', 'another store''s product reads as unknown');
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-x', jsonb_build_object('lines', jsonb_build_array(
            pg_temp.line('v_scarf', 1), pg_temp.line('v_L', 1)))) -> 'error' -> 'details' -> 'fields',
          '{"lines.0.variant_id": "unavailable", "lines.1.variant_id": "unavailable"}'::jsonb,
          'inactive products and archived options are refused');
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-x', jsonb_build_object('lines', jsonb_build_array(pg_temp.line('v_S', 6))))
            #>> '{error,details,fields,lines.0.quantity}', 'exceeds_stock', 'the AI cannot draft more than the stock');
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-x', jsonb_build_object('customer_phone', '0750', 'lines',
            jsonb_build_array(pg_temp.line('v_S', 0), pg_temp.line('v_M', 1, 'guessed')))) -> 'error' -> 'details' -> 'fields',
          '{"customer_phone": "invalid", "lines.0.quantity": "out_of_range", "lines.1.quantity_basis": "invalid"}'::jsonb,
          'phone, quantity and quantity basis are validated');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.orders where ai_ref = 'conv-x' and store_id = pg_temp.id('store_a')), 0,
          'refused requests create nothing');
select pg_temp.act_as_ai();
insert into res select 'c3', pg_temp.ai(pg_temp.sec('g'), 'conv-3', jsonb_build_object('customer_name', 'Rozh',
  'city_text', 'Koya', 'lines', jsonb_build_array(pg_temp.line('v_S', 2, 'inferred'))));
select is(pg_temp.r('c3') #>> '{data,status}', 'draft', 'an incomplete AI order is a draft');
select is((select jsonb_agg(x ->> 'field' || ':' || (x ->> 'kind')) from jsonb_array_elements(pg_temp.r('c3') #> '{data,issues}') x),
          '["customer_phone:missing", "area:missing", "delivery_fee:missing", "payment_method:missing", "lines:quantity_inferred"]'::jsonb,
          'outside the zones the AI quotes no fee, and an inferred quantity blocks approval');

-- ---- The grant decides the store and the conversation ---------------------------------------------
select is(pg_temp.ai(repeat('0', 10), 'conv-1', '{}') #>> '{error,code}', 'AI_GRANT_INVALID', 'a malformed grant is refused');
select is(pg_temp.ai('aig_' || repeat('0', 64), 'conv-1', '{}') #>> '{error,code}', 'AI_GRANT_INVALID', 'an unknown grant is refused');
select is(pg_temp.ai(pg_temp.sec('g2'), 'conv-1', '{"area": "Elsewhere"}') #>> '{error,code}', 'AI_GRANT_SCOPE',
          'a grant limited to one conversation cannot touch another');
select is(pg_temp.ai(pg_temp.sec('g2'), 'conv-2', jsonb_build_object('lines', jsonb_build_array(pg_temp.line('v_S', 1))))
            #>> '{data,status}', 'draft', '… and works for its own conversation');
insert into res select 'cb', pg_temp.ai(pg_temp.sec('gb'), 'conv-1', jsonb_build_object('customer_name', 'B customer'));
select ok((pg_temp.r('cb') #>> '{data,order_id}')::uuid <> pg_temp.id('o1'),
          'the same conversation reference under seller B''s grant is a separate order in B''s store');
select pg_temp.act_as_admin();
select is((select store_id from app.orders where id = (pg_temp.r('cb') #>> '{data,order_id}')::uuid), pg_temp.id('store_b'),
          '… the store comes from the grant, never from the caller');
select is((select customer_name from app.orders where id = pg_temp.id('o1')), 'Nzar Ahmad', 'seller A''s order is untouched');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.revoke_ai_draft_grant(pg_temp.id('store_a'), (pg_temp.r('g2') #>> '{data,grant_id}')::uuid) #>> '{data,revoked}',
          'true', 'the owner revokes a grant');
select pg_temp.act_as_ai();
select is(pg_temp.ai(pg_temp.sec('g2'), 'conv-2', '{"area": "Centre"}') #>> '{error,code}', 'AI_GRANT_INVALID',
          'a revoked grant stops working at once');
select pg_temp.act_as_admin();
update app.ai_draft_grants set created_at = now() - interval '2 days', expires_at = now() - interval '1 day'
 where store_id = pg_temp.id('store_b');
select pg_temp.act_as_ai();
select is(pg_temp.ai(pg_temp.sec('gb'), 'conv-1', '{"area": "Centre"}') #>> '{error,code}', 'AI_GRANT_INVALID',
          'an expired grant is refused');

-- ---- Seller edits win; closed orders are off limits ---------------------------------------------------
select pg_temp.act_as(pg_temp.id('a'));
select is(api.update_draft(pg_temp.id('store_a'), pg_temp.id('o1'), 1,
  pg_temp.full_order(jsonb_build_array(pg_temp.line('v_M', 1))) || '{"customer_name": "Nzar A."}', gen_random_uuid())
  #> '{data,seller_edited}', '["customer_name", "lines"]'::jsonb, 'the seller''s changes are recorded field by field');
select pg_temp.act_as_ai();
insert into res select 'u1', pg_temp.ai(pg_temp.sec('g'), 'conv-1', jsonb_build_object(
  'customer_name', 'Nazar', 'landmark', 'Near the church', 'lines', jsonb_build_array(pg_temp.line('v_M', 3))));
select is(pg_temp.r('u1') #> '{data,skipped_fields}', '["customer_name", "lines"]'::jsonb,
          'the AI''s values for seller-edited fields are skipped and reported');
select pg_temp.act_as_admin();
select is((select customer_name || ' · ' || landmark from app.orders where id = pg_temp.id('o1')), 'Nzar A. · Near the church',
          'the seller''s name stays; an untouched field takes the AI''s value');
select is((select quantity || ' ' || quantity_basis from app.order_items where order_id = pg_temp.id('o1')), '1 confirmed',
          'the seller''s lines and confirmed quantities stay');
select is((select (after ->> 'actor') || ' ' || (after ->> 'landmark') from app.audit_events
            where entity_id = pg_temp.id('o1') and action = 'order.ai_update'), 'ai Near the church',
          'AI edits are audited as the AI''s');
select pg_temp.act_as(pg_temp.id('a'));
select is((select string_agg(x ->> 'actor', ',' order by x ->> 'actor') from jsonb_array_elements(
            api.order_history(pg_temp.id('store_a'), pg_temp.id('o1')) #> '{data,items}') x where x ->> 'kind' = 'edit'),
          'ai,you', 'history shows the seller''s edit and the AI''s edit, each with its actor');
select is(api.approve_order(pg_temp.id('store_a'), pg_temp.id('o1'), 3, '{}', gen_random_uuid()) #>> '{data,status}', 'approved',
          'the owner approves the AI''s order in the normal way');
select pg_temp.act_as_ai();
select is(((pg_temp.ai(pg_temp.sec('g'), 'conv-1', '{"area": "Elsewhere"}') -> 'error') - 'details') ||
            jsonb_build_object('status', pg_temp.ai(pg_temp.sec('g'), 'conv-1', '{"area": "Elsewhere"}') #>> '{error,details,current_status}'),
          '{"code": "DRAFT_CLOSED", "status": "approved"}'::jsonb,
          'once the seller approved it, the AI cannot change it');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.reject_draft(pg_temp.id('store_a'), (pg_temp.r('c3') #>> '{data,order_id}')::uuid, 1, 'duplicate', null, gen_random_uuid())
            #>> '{data,status}', 'rejected', 'the seller rejects an AI draft');
select pg_temp.act_as_ai();
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-3', '{"area": "Centre"}') #>> '{error,code}', 'DRAFT_CLOSED',
          'a rejected AI draft is not resurrected');
select pg_temp.act_as_admin();
select is((select area from app.orders where id = pg_temp.id('o1')), 'Ankawa', 'the closed orders are unchanged');

-- ---- The AI role cannot do anything else ------------------------------------------------------------
select pg_temp.act_as_ai();
select throws_ok(format($$ select api.approve_order(%L, %L, 4, '{}', gen_random_uuid()) $$, pg_temp.id('store_a'), pg_temp.id('o1')),
                 '42501', null, 'the AI cannot approve');
select throws_ok(format($$ select api.reject_draft(%L, %L, 1, 'duplicate', null, gen_random_uuid()) $$, pg_temp.id('store_a'), pg_temp.id('o1')),
                 '42501', null, 'the AI cannot reject');
select throws_ok(format($$ select api.cancel_order(%L, %L, 4, 'duplicate', null, gen_random_uuid()) $$, pg_temp.id('store_a'), pg_temp.id('o1')),
                 '42501', null, 'the AI cannot cancel');
select throws_ok(format($$ select api.transition_order(%L, %L, 4, 'dispatched', '{}', gen_random_uuid()) $$, pg_temp.id('store_a'), pg_temp.id('o1')),
                 '42501', null, 'the AI cannot dispatch or deliver');
select throws_ok(format($$ select api.record_return(%L, %L, 4, '[]', null, gen_random_uuid()) $$, pg_temp.id('store_a'), pg_temp.id('o1')),
                 '42501', null, 'the AI cannot record a return');
select throws_ok(format($$ select api.update_draft(%L, %L, 1, '{}', gen_random_uuid()) $$, pg_temp.id('store_a'), pg_temp.id('o1')),
                 '42501', null, 'the AI cannot use the seller''s editing functions');
select throws_ok(format($$ select api.get_order(%L, %L) $$, pg_temp.id('store_a'), pg_temp.id('o1')),
                 '42501', null, 'the AI cannot read orders through the seller''s functions');
select throws_ok(format($$ select api.create_ai_draft_grant(%L, null, null, 24) $$, pg_temp.id('store_a')),
                 '42501', null, 'the AI cannot issue itself a grant');
select throws_ok($$ select count(*) from app.orders $$, '42501', null, 'the AI cannot read tables directly');
select throws_ok(format($$ update app.orders set status = 'approved' where id = %L $$, pg_temp.id('o1')),
                 '42501', null, 'the AI cannot write tables directly');
select throws_ok($$ select count(*) from storage.objects $$, '42501', null, 'the AI cannot reach storage');
-- A forged claim does not help: the database role still decides what may run.
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', pg_temp.id('a'))::text, true);
select throws_ok(format($$ select api.approve_order(%L, %L, 4, '{}', gen_random_uuid()) $$, pg_temp.id('store_a'), pg_temp.id('o1')),
                 '42501', null, 'the AI role with an owner''s claims still cannot approve');
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-9', '{}') #>> '{error,code}', 'FORBIDDEN',
          'and the AI function refuses any caller whose token is not the AI''s');
select pg_temp.act_as(pg_temp.id('a'));
select throws_ok(format($$ select api.ai_upsert_draft(%L, 'conv-9', '{}', gen_random_uuid()) $$, pg_temp.sec('g')),
                 '42501', null, 'an end user (even the owner) cannot call the AI function');

-- ---- Quotas -----------------------------------------------------------------------------------------
select pg_temp.act_as_admin();
update app.ai_limits set value = 3 where name = 'calls_per_grant_per_minute';
select pg_temp.act_as(pg_temp.id('a'));
insert into secrets select 'g3', api.create_ai_draft_grant(pg_temp.id('store_a'), null, null, 1) #>> '{data,secret}';
insert into secrets select 'g4', api.create_ai_draft_grant(pg_temp.id('store_a'), null, null, 1) #>> '{data,secret}';
insert into ids values ('k3', gen_random_uuid());
select pg_temp.act_as_ai();
insert into res select 'q1', pg_temp.ai(pg_temp.sec('g3'), 'conv-q', '{"customer_name": "Q"}', pg_temp.id('k3'));
select is((pg_temp.ai(pg_temp.sec('g3'), 'conv-q', '{"area": "One"}') #>> '{data,status}')
          || (pg_temp.ai(pg_temp.sec('g3'), 'conv-q', '{"area": "Two"}') #>> '{data,status}'), 'draftdraft',
          'calls within the per-grant rate pass');
select is(((pg_temp.ai(pg_temp.sec('g3'), 'conv-q', '{"area": "Three"}') -> 'error') - 'details') ||
            jsonb_build_object('scope', pg_temp.ai(pg_temp.sec('g3'), 'conv-q', '{"area": "Four"}') #>> '{error,details,scope}'),
          '{"code": "RATE_LIMITED", "scope": "grant"}'::jsonb, 'the next call within the minute is refused');
select is(pg_temp.ai(pg_temp.sec('g3'), 'conv-q', '{"customer_name": "Q"}', pg_temp.id('k3')), pg_temp.r('q1'),
          'a replay of an earlier request is still answered (it does no new work)');
select is(pg_temp.ai(pg_temp.sec('g4'), 'conv-q', '{"area": "Other grant"}') #>> '{data,status}', 'draft',
          'another grant has its own rate');
select pg_temp.act_as_admin();
select is((select array_agg(outcome order by id) from app.ai_requests
            where grant_id = (select id from app.ai_draft_grants where secret_hash = app.secret_hash(pg_temp.sec('g3')))),
          array['created', 'updated', 'updated', 'RATE_LIMITED', 'RATE_LIMITED'],
          'every call is logged with its outcome (refusals included)');
select is((select array_agg(column_name::text order by column_name) from information_schema.columns
            where table_schema = 'app' and table_name = 'ai_requests'),
          array['created_at', 'grant_id', 'id', 'order_id', 'outcome', 'store_id'],
          'the log holds no payload and no customer data');
update app.ai_limits set value = (select count(*) from app.orders where store_id = pg_temp.id('store_a') and origin = 'ai') + 1
 where name = 'drafts_per_store_per_day';
update app.ai_limits set value = 100 where name = 'calls_per_grant_per_minute';
select pg_temp.act_as_ai();
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-new-1', '{"customer_name": "N1"}') #>> '{data,created}', 'true',
          'new AI drafts within the store''s daily quota pass');
select is(((pg_temp.ai(pg_temp.sec('g'), 'conv-new-2', '{"customer_name": "N2"}') -> 'error') - 'details') ||
            jsonb_build_object('scope', 'store'),
          '{"code": "RATE_LIMITED", "scope": "store"}'::jsonb, 'the next new draft that day is refused');
select is(pg_temp.ai(pg_temp.sec('g'), 'conv-new-1', '{"area": "Centre"}') #>> '{data,created}', 'false',
          'updating an existing AI draft is not a new draft');

select * from finish();
rollback;
