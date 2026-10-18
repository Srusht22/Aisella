-- Customer privacy: masked phones in the order audit, an append-only audit, and the owner's
-- "delete this customer" (Phase 1 BR-72, Phase 3 §7.1–7.2) that keeps the order's financial facts.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(33);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
create function pg_temp.ver(p text) returns integer language sql as $$ select version from app.orders where id = pg_temp.id(p) $$;

insert into ids values ('a', pg_temp.new_user('privacy-a@example.test')), ('b', pg_temp.new_user('privacy-b@example.test')),
  ('staff', pg_temp.new_user('privacy-staff@example.test'));

select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'zone_a', (api.upsert_zone(pg_temp.id('store_a'), null, null, 'Erbil', 5000, null, gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v_a', (api.upsert_product(pg_temp.id('store_a'), gen_random_uuid(), null,
  '{"name": "Abaya A", "base_price": 35000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 9}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
create function pg_temp.order_of(p_name text, p_phone text, p_phone2 text default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('customer_name', p_name, 'customer_phone', p_phone, 'customer_phone2', p_phone2,
                            'zone_id', pg_temp.id('zone_a'), 'area', 'Ankawa', 'landmark', 'Near the blue mosque',
                            'address_details', 'Street 40, house 12', 'customer_note', 'Call after 5', 'payment_method', 'cod',
                            'internal_note', 'regular buyer',
                            'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_a'), 'quantity', 1))))
$$;
create function pg_temp.go(p_key text, p_to text, p_payload jsonb default '{}') returns jsonb language sql as $$
  select api.transition_order(pg_temp.id('store_a'), pg_temp.id(p_key), pg_temp.ver(p_key), p_to, p_payload, gen_random_uuid())
$$;

-- delivered: Nzar's delivered order (created with an idempotency key we keep).
insert into ids values ('k_create', gen_random_uuid());
insert into ids select 'delivered', (api.create_order(pg_temp.id('store_a'), pg_temp.order_of('Nzar Ahmad', '+9647501112233'),
                                                      pg_temp.id('k_create')) #>> '{data,id}')::uuid;
select api.update_draft(pg_temp.id('store_a'), pg_temp.id('delivered'), 1,
                        pg_temp.order_of('Nzar Ahmad', '+9647501112233', '+9647709998877'), gen_random_uuid());
select api.approve_order(pg_temp.id('store_a'), pg_temp.id('delivered'), pg_temp.ver('delivered'), '{}', gen_random_uuid());
select pg_temp.go('delivered', 'dispatched');
select pg_temp.go('delivered', 'delivered', '{"cod_collected": 40000}');
-- rejected: an order where Nzar is the second phone. pending: still being handled.
insert into ids select 'rejected', (api.create_order(pg_temp.id('store_a'), pg_temp.order_of('Nzar (work)', '+9647505550000', '+9647501112233'),
                                                     gen_random_uuid()) #>> '{data,id}')::uuid;
select api.reject_draft(pg_temp.id('store_a'), pg_temp.id('rejected'), 1, 'duplicate', null, gen_random_uuid());
insert into ids select 'pending', (api.create_order(pg_temp.id('store_a'), pg_temp.order_of('Nzar Ahmad', '+9647501112233'),
                                                    gen_random_uuid()) #>> '{data,id}')::uuid;
-- another customer of A.
insert into ids select 'other', (api.create_order(pg_temp.id('store_a'), pg_temp.order_of('Shno Ali', '+9647504443322'),
                                                  gen_random_uuid()) #>> '{data,id}')::uuid;
select api.reject_draft(pg_temp.id('store_a'), pg_temp.id('other'), 1, 'duplicate', null, gen_random_uuid());
select is((select status from app.orders where id = pg_temp.id('delivered')), 'delivered', 'setup: a delivered order');

-- Seller B has a closed order for the same phone number.
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'ckb', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v_b', (api.upsert_product(pg_temp.id('store_b'), gen_random_uuid(), null,
  '{"name": "Mug B", "base_price": 3000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 5}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
insert into ids select 'b_order', (api.create_order(pg_temp.id('store_b'), jsonb_build_object('customer_name', 'Nzar Ahmad',
  'customer_phone', '+9647501112233', 'city_text', 'Duhok', 'payment_method', 'cod',
  'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_b'), 'quantity', 1))), gen_random_uuid()) #>> '{data,id}')::uuid;
select api.reject_draft(pg_temp.id('store_b'), pg_temp.id('b_order'), 1, 'duplicate', null, gen_random_uuid());

-- ---- Minimisation: the audit stores masked phones ----------------------------------------------------
select pg_temp.act_as_admin();
select is((select after ->> 'customer_phone' from app.audit_events
            where entity_id = pg_temp.id('delivered') and action = 'order.create'),
          '+964750***2233', 'the order audit stores the phone masked');
select is((select after ->> 'customer_phone2' from app.audit_events
            where entity_id = pg_temp.id('delivered') and action = 'order.update_draft'),
          '+964770***8877', '… the second phone too');
select ok(not exists (select 1 from app.audit_events where entity_type = 'order'
                       and (before::text like '%9647501112233%' or after::text like '%9647501112233%')),
          'no order audit row holds a full phone number');
-- A phone change hidden by the mask is still recorded as a change.
select pg_temp.act_as(pg_temp.id('a'));
select api.update_draft(pg_temp.id('store_a'), pg_temp.id('pending'), pg_temp.ver('pending'),
                        pg_temp.order_of('Nzar Ahmad', '+9647509992233'), gen_random_uuid());
select pg_temp.act_as_admin();
select is((select jsonb_build_array(before ->> 'customer_phone', after ->> 'customer_phone') from app.audit_events
            where entity_id = pg_temp.id('pending') and action = 'order.update_draft' order by id desc limit 1),
          '["+964750***2233", "+964750***2233"]'::jsonb, 'a phone change is recorded even when both masked forms match');
select pg_temp.act_as(pg_temp.id('a'));
select api.update_draft(pg_temp.id('store_a'), pg_temp.id('pending'), pg_temp.ver('pending'),
                        pg_temp.order_of('Nzar Ahmad', '+9647501112233'), gen_random_uuid());

-- ---- Integrity: the audit is append-only ---------------------------------------------------------------
select pg_temp.act_as_admin();
select throws_ok($$ update app.audit_events set action = 'x' where entity_id = pg_temp.id('delivered') $$, 'AS002', null,
                 'even the database owner cannot rewrite an audit row');
select throws_ok($$ delete from app.audit_events where entity_id = pg_temp.id('delivered') $$, 'AS002', null,
                 '… nor delete one outside the account purge');
select set_config('aisellia.redact', 'on', true);
select throws_ok($$ update app.audit_events set action = 'x' where entity_id = pg_temp.id('delivered') $$, 'AS002', null,
                 'the redaction flag allows only values to change, never who did what or when');
select set_config('aisellia.redact', 'off', true);

-- ---- Who may anonymise ---------------------------------------------------------------------------------
insert into app.store_members (store_id, user_id, role, permissions)
values (pg_temp.id('store_a'), pg_temp.id('staff'), 'staff', '{"customers.delete": true}');
select pg_temp.act_as(pg_temp.id('staff'));
select is(api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', gen_random_uuid()) #>> '{error,code}', 'FORBIDDEN',
          'staff cannot delete a customer, even with the permission (owner only)');
select pg_temp.act_as(pg_temp.id('b'));
select is(api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', gen_random_uuid()) #>> '{error,code}', 'NOT_FOUND',
          'seller B cannot anonymise seller A''s customers');
select pg_temp.act_as_anon();
select throws_ok($$ select api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', gen_random_uuid()) $$, '42501', null,
                 'anon cannot call it');
select pg_temp.act_as_admin();
grant usage on schema extensions to aisellia_ai;   -- pgTAP itself; rolled back
set local role aisellia_ai;
select throws_ok($$ select api.anonymize_customer(gen_random_uuid(), '+9647501112233', gen_random_uuid()) $$, '42501', null,
                 'the AI role cannot call it');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.orders where customer_anonymized_at is not null
            and store_id in (pg_temp.id('store_a'), pg_temp.id('store_b'))), 0, 'none of the refused calls changed an order');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.anonymize_customer(pg_temp.id('store_a'), '0750 111 2233', gen_random_uuid()) #>> '{error,details,fields,phone}',
          'invalid', 'the phone must be in the stored form');

-- ---- Anonymise --------------------------------------------------------------------------------------------
insert into ids values ('k_anon', gen_random_uuid());
insert into res select 'anon', api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', pg_temp.id('k_anon'));
select is((pg_temp.r('anon') -> 'data') - 'order_ids', '{"anonymized": 2, "skipped_in_progress": 1, "notes_redacted": 0, "contacts_anonymized": 0, "contacts_skipped_in_progress": 0}'::jsonb,
          'the delivered and the rejected order are anonymised; the pending one is skipped and reported');
select is((select jsonb_agg(x order by x) from jsonb_array_elements_text(pg_temp.r('anon') #> '{data,order_ids}') x),
          (select jsonb_agg(x order by x) from unnest(array[pg_temp.id('delivered')::text, pg_temp.id('rejected')::text]) x),
          '… and they are named');
select pg_temp.act_as_admin();
select is((select row(customer_name, customer_phone, customer_phone2, area, landmark, address_details, customer_note,
                      customer_anonymized_at is not null)::text
             from app.orders where id = pg_temp.id('delivered')),
          row(null::text, null::text, null::text, null::text, null::text, null::text, null::text, true)::text,
          'the contact data is gone from the order');
select is((select row(status, total, subtotal, delivery_fee, cod_collected, approved_by is not null, zone_name, internal_note)::text
             from app.orders where id = pg_temp.id('delivered')),
          row('delivered', 40000, 35000, 5000, 40000, true, 'Erbil', 'regular buyer')::text,
          'status, totals, fee, COD, approval, zone and the seller''s own note stay');
select is((select count(*)::integer from app.order_items where order_id = pg_temp.id('delivered')), 1, 'the lines stay');
select is((select count(*)::integer from app.order_status_events where order_id = pg_temp.id('delivered')), 4,
          'the status history stays');
select ok(exists (select 1 from app.inventory_movements where order_id = pg_temp.id('delivered')), 'the stock movements stay');
select ok((select search_text not like '%nzar%' and phone_digits = '' from app.orders where id = pg_temp.id('delivered')),
          'search no longer finds the order by the customer''s name or phone');
select is((select count(*)::integer from app.audit_events where entity_id = pg_temp.id('delivered')),
          (select count(*)::integer from app.audit_events where entity_id = pg_temp.id('delivered') and actor_user_id = pg_temp.id('a')),
          'every audit row of the order stays, with who did it');
select ok(not exists (select 1 from app.audit_events
                       where entity_id in (pg_temp.id('delivered'), pg_temp.id('rejected'))
                         and (coalesce(before::text, '') || coalesce(after::text, '')) ~ '(Nzar|2233|8877|Ankawa|blue mosque|house 12|after 5)'),
          'the audit rows no longer hold the name, phones, address or customer note');
select is((select after ->> 'customer_name' from app.audit_events
            where entity_id = pg_temp.id('delivered') and action = 'order.create'), '[redacted]',
          'redacted values are marked, so the history still shows what was recorded');
select ok(not exists (select 1 from app.idempotency_keys where key = pg_temp.id('k_create')),
          'the stored response of the order''s creation (which repeated the contact data) is gone');
select is((select customer_name from app.orders where id = pg_temp.id('pending')), 'Nzar Ahmad',
          'the order still in progress keeps its contact data');
select is((select customer_name from app.orders where id = pg_temp.id('other')), 'Shno Ali', 'other customers are untouched');
select is((select customer_name from app.orders where id = pg_temp.id('b_order')), 'Nzar Ahmad',
          'seller B''s order for the same phone is untouched');
select is((select after from app.audit_events where store_id = pg_temp.id('store_a') and action = 'customer.anonymize'),
          '{"orders": 2, "skipped_in_progress": 1, "notes_redacted": 0, "contacts": 0, "contacts_skipped_in_progress": 0}'::jsonb, 'the anonymisation itself is audited, without the phone');

-- Replay and repeat.
select pg_temp.act_as(pg_temp.id('a'));
select is(api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', pg_temp.id('k_anon')), pg_temp.r('anon'),
          'a retry with the same key replays the answer');
select is((api.anonymize_customer(pg_temp.id('store_a'), '+9647501112233', gen_random_uuid()) -> 'data') - 'order_ids',
          '{"anonymized": 0, "skipped_in_progress": 1, "notes_redacted": 0, "contacts_anonymized": 0, "contacts_skipped_in_progress": 0}'::jsonb, 'a second request finds nothing more to anonymise');
select pg_temp.act_as_admin();
select ok(not exists (select 1 from app.idempotency_keys where key = pg_temp.id('k_anon') and request_hash like '%2233%'),
          'the stored request does not hold the phone');

select * from finish();
rollback;
