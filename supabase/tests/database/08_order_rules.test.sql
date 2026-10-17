-- Orders: creation, validation, drafts, rejection, lists and storage guards
-- (Phase 1 BR-20, BR-23..BR-25, BR-30, BR-32, BR-34..BR-37; Phase 3 §6.1, §6.5; Phase 2 OR-01, OR-02, OR-04, OR-11).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(60);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;

insert into ids values ('a', pg_temp.new_user('orders@example.test')), ('abaya', gen_random_uuid()),
  ('wrap', gen_random_uuid()), ('old', gen_random_uuid());
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store', (api.create_store('Nasreen Boutique', '+9647501234567', 'IQD', 'ckb', 'Erbil',
                                                  gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'zone', (api.upsert_zone(pg_temp.id('store'), null, null, 'Erbil', 5000, null,
                                                gen_random_uuid()) #>> '{data,id}')::uuid;
insert into res select 'abaya', api.upsert_product(pg_temp.id('store'), pg_temp.id('abaya'), null,
  '{"name": "Beige Abaya", "base_price": 35000, "track_stock": true, "status": "active", "option_types": ["Size"],
    "variants": [{"option_values": ["S"], "sku": "AB-S", "initial_stock": 5},
                 {"option_values": ["M"], "sku": "AB-M", "initial_stock": 4},
                 {"option_values": ["L"], "status": "archived"}], "images": []}', gen_random_uuid());
insert into ids select 'v_' || (x ->> 'label'), (x ->> 'id')::uuid
  from jsonb_array_elements(pg_temp.r('abaya') #> '{data,variants}') x;
insert into ids select 'v_wrap', (api.upsert_product(pg_temp.id('store'), pg_temp.id('wrap'), null,
  '{"name": "Gift wrap", "base_price": 2000, "track_stock": false, "status": "active", "option_types": [],
    "variants": [{"option_values": []}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
insert into ids select 'v_old', (api.upsert_product(pg_temp.id('store'), pg_temp.id('old'), null,
  '{"name": "Old scarf", "base_price": 1000, "track_stock": true, "status": "inactive", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 3}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;

create function pg_temp.line(p_variant text, p_qty integer) returns jsonb language sql as $$
  select jsonb_build_object('variant_id', pg_temp.id(p_variant), 'quantity', p_qty)
$$;
create function pg_temp.full_order(p_lines jsonb) returns jsonb language sql as $$
  select jsonb_build_object('customer_name', 'Nzar Ahmad', 'customer_phone', '+9647501112233',
                            'zone_id', pg_temp.id('zone'), 'area', 'Ankawa', 'payment_method', 'cod',
                            'lines', p_lines)
$$;
create function pg_temp.stock(p_variant text) returns integer language sql as $$
  select stock_on_hand from app.product_variants where id = pg_temp.id(p_variant)
$$;

-- ---- Create a complete manual order (BR-31) --------------------------------------------------
insert into ids values ('k1', gen_random_uuid());
insert into res select 'o1', api.create_order(pg_temp.id('store'),
  pg_temp.full_order(jsonb_build_array(pg_temp.line('v_M', 2), pg_temp.line('v_wrap', 1))), pg_temp.id('k1'));
insert into ids select 'o1', (pg_temp.r('o1') #>> '{data,id}')::uuid;
select is(pg_temp.r('o1') #>> '{data,status}', 'pending_approval',
          'a complete manual order needs approval: it is never created approved');
select is(pg_temp.r('o1') #>> '{data,number}', '1001', 'order numbers start at #1001 (BR-35)');
select is((pg_temp.r('o1') #>> '{data,subtotal}') || '+' || (pg_temp.r('o1') #>> '{data,delivery,fee}') || '=' ||
          (pg_temp.r('o1') #>> '{data,total}'), '72000+5000=77000',
          'subtotal, fee and total are computed by the server (BR-24)');
select is((select jsonb_agg(jsonb_build_array(x ->> 'name', x ->> 'variant_label', x ->> 'sku', x ->> 'quoted_unit_price'))
             from jsonb_array_elements(pg_temp.r('o1') #> '{data,lines}') x),
          '[["Beige Abaya", "M", "AB-M", "35000"], ["Gift wrap", "", null, "2000"]]'::jsonb,
          'lines carry name, variant, SKU and quoted price snapshots');
select is(pg_temp.r('o1') #>> '{data,delivery,zone_name}', 'Erbil', 'the zone name is snapshotted');
select is(pg_temp.r('o1') #>> '{data,delivery,fee_source}', 'zone', '… and the fee comes from the zone');
select is(pg_temp.r('o1') -> 'data' -> 'events',
          jsonb_build_array(jsonb_build_object('from', null, 'to', 'pending_approval', 'actor', 'you', 'reason', null,
                                               'note', null, 'created_at', pg_temp.r('o1') #> '{data,events,0,created_at}')),
          'creation is one status event (∅ → pending_approval) by the seller (BR-34)');
select is(pg_temp.stock('v_M'), 4, 'creating an order does not touch stock (BR-20)');
select is((select count(*)::integer from app.inventory_movements where order_id is not null), 0, '… and writes no movement');
select is(pg_temp.r('o1') #>> '{data,approved_by}', 'system', 'nobody approved it');
select is(api.create_order(pg_temp.id('store'),
            pg_temp.full_order(jsonb_build_array(pg_temp.line('v_M', 2), pg_temp.line('v_wrap', 1))), pg_temp.id('k1')),
          pg_temp.r('o1'), 'a retry with the same key replays the same order');
select is((select count(*)::integer from app.orders), 1, '… and creates no second order');
select is(api.create_order(pg_temp.id('store'), pg_temp.full_order(jsonb_build_array(pg_temp.line('v_M', 3))),
                           pg_temp.id('k1')) #>> '{error,code}',
          'IDEMPOTENCY_KEY_REUSED', 'the same key with another order is refused');

-- ---- Drafts (BR-36) ------------------------------------------------------------------------
insert into res select 'o2', api.create_order(pg_temp.id('store'),
  jsonb_build_object('customer_name', 'Rozh', 'city_text', 'Koya', 'lines', jsonb_build_array(pg_temp.line('v_S', 1))),
  gen_random_uuid());
insert into ids select 'o2', (pg_temp.r('o2') #>> '{data,id}')::uuid;
select is(pg_temp.r('o2') #>> '{data,status}', 'draft', 'an incomplete order is a draft');
select is((select jsonb_agg(x ->> 'field') from jsonb_array_elements(pg_temp.r('o2') #> '{data,issues}') x),
          '["customer_phone", "area", "delivery_fee", "payment_method"]'::jsonb,
          'the draft lists what is missing, in order');
select is(pg_temp.r('o2') #>> '{data,number}', '1002', 'numbers are sequential per store');

-- ---- Nothing the server computes can be sent --------------------------------------------------
select is(api.create_order(pg_temp.id('store'), pg_temp.full_order('[]') ||
            '{"status": "approved", "total": 1, "approved_by": "00000000-0000-0000-0000-000000000000", "store_id": null}',
            gen_random_uuid()) #> '{error,details,fields}',
          '{"status": "unknown", "total": "unknown", "approved_by": "unknown", "store_id": "unknown"}'::jsonb,
          'status, total, approver and store from the client are refused, not trusted');
select is(api.create_order(pg_temp.id('store'), jsonb_build_object('lines',
            jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_M'), 'quantity', 1, 'unit_price', 1)))
          , gen_random_uuid()) #>> '{error,details,fields,lines.0.unit_price}',
          'unknown', 'a line price from the client is refused (prices come from the catalog)');
select is(api.create_order(pg_temp.id('store'), jsonb_build_object(
            'customer_phone', '0750', 'delivery_fee', -1, 'discount', '5', 'payment_method', 'card',
            'lines', jsonb_build_array(pg_temp.line('v_M', 0), pg_temp.line('v_S', 1000))), gen_random_uuid()) #> '{error,details,fields}',
          '{"customer_phone": "invalid", "delivery_fee": "invalid", "discount": "invalid", "payment_method": "invalid",
            "lines.0.quantity": "out_of_range", "lines.1.quantity": "out_of_range"}'::jsonb,
          'fields are validated together; quantity is 1–999 (BR-37)');
select is(api.create_order(pg_temp.id('store'), jsonb_build_object('lines',
            jsonb_build_array(jsonb_build_object('variant_id', gen_random_uuid(), 'quantity', 1))), gen_random_uuid())
            #>> '{error,details,fields,lines.0.variant_id}', 'unknown', 'an unknown variant is refused');
select is(api.create_order(pg_temp.id('store'), jsonb_build_object('lines',
            jsonb_build_array(pg_temp.line('v_M', 1), pg_temp.line('v_M', 2))), gen_random_uuid())
            #>> '{error,details,fields,lines.1.variant_id}', 'duplicate', 'one line per variant');
select is(api.create_order(pg_temp.id('store'), jsonb_build_object('lines',
            jsonb_build_array(pg_temp.line('v_L', 1), pg_temp.line('v_old', 1))), gen_random_uuid()) #> '{error,details,fields}',
          '{"lines.0.variant_id": "unavailable", "lines.1.variant_id": "unavailable"}'::jsonb,
          'archived variants and inactive products cannot be added (BR-17)');
select is(api.create_order(pg_temp.id('store'), pg_temp.full_order(jsonb_build_array(pg_temp.line('v_wrap', 1)))
            || '{"discount": 2001}', gen_random_uuid()) #>> '{error,details,fields,discount}',
          'exceeds_subtotal', 'the discount cannot exceed the subtotal (BR-25)');
select is(api.create_order(pg_temp.id('store'), '{"payment_method": "other"}', gen_random_uuid())
            #>> '{error,details,fields,payment_method}', 'disabled', 'a payment method the store has not enabled is refused');
select is((select count(*)::integer from app.orders), 2, 'refused requests create nothing');

-- ---- Delivery fee: zone or seller ------------------------------------------------------------
insert into res select 'o3', api.create_order(pg_temp.id('store'),
  pg_temp.full_order(jsonb_build_array(pg_temp.line('v_S', 1))) || '{"delivery_fee": 3000, "discount": 1000}', gen_random_uuid());
select is((pg_temp.r('o3') #>> '{data,delivery,fee_source}') || ' ' || (pg_temp.r('o3') #>> '{data,total}'),
          'seller 37000', 'a seller fee overrides the zone fee; the discount is subtracted');

-- ---- Edit a draft: draft ↔ pending re-evaluated (BR-30) ---------------------------------------
-- The catalog price of S changes (as an admin shortcut; the editor path is covered in 05).
select pg_temp.act_as_admin();
update app.product_variants set price_override = 30000 where id = pg_temp.id('v_S');
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'o2e', api.update_draft(pg_temp.id('store'), pg_temp.id('o2'), 1,
  jsonb_build_object('customer_name', 'Rozh', 'customer_phone', '07501112233', 'city_text', 'Koya'), gen_random_uuid());
select is(pg_temp.r('o2e') #>> '{error,details,fields,customer_phone}', 'invalid',
          'phones are stored normalised: the app sends +9647…');
insert into res select 'o2e', api.update_draft(pg_temp.id('store'), pg_temp.id('o2'), 1,
  jsonb_build_object('customer_name', 'Rozh', 'customer_phone', '+9647501112244', 'city_text', 'Koya',
                     'delivery_fee', 7000, 'area', 'Centre', 'payment_method', 'cod',
                     'lines', jsonb_build_array(pg_temp.line('v_S', 2), pg_temp.line('v_M', 1))), gen_random_uuid())
  on conflict (k) do update set v = excluded.v;
select is(pg_temp.r('o2e') #>> '{data,status}', 'pending_approval', 'completing a draft makes it pending approval');
select is((pg_temp.r('o2e') #> '{data,events,1}') - 'created_at',
          '{"from": "draft", "to": "pending_approval", "actor": "system", "reason": null, "note": null}'::jsonb,
          '… recorded as an automatic status event');
select is((select jsonb_agg(jsonb_build_array(x ->> 'variant_label', x ->> 'quoted_unit_price'))
             from jsonb_array_elements(pg_temp.r('o2e') #> '{data,lines}') x),
          '[["S", "35000"], ["M", "35000"]]'::jsonb,
          'a kept line keeps its quoted price after a catalog change (BR-23)');
select is(pg_temp.r('o2e') #>> '{data,lines,0,current,price}', '30000', '… and shows the current catalog price beside it');
select is(api.update_draft(pg_temp.id('store'), pg_temp.id('o2'), 1, '{}', gen_random_uuid()) #>> '{error,code}',
          'CONFLICT_VERSION', 'an edit of an out-of-date version is refused');
insert into res select 'o2f', api.update_draft(pg_temp.id('store'), pg_temp.id('o2'), 2,
  (pg_temp.r('o2e') -> 'data' -> 'customer') - 'phone' || '{}'::jsonb, gen_random_uuid());
select is(pg_temp.r('o2f') #> '{error,details,fields}', '{"name": "unknown", "phone2": "unknown"}'::jsonb,
          'the payload uses the documented field names only');
insert into res select 'o2f', api.update_draft(pg_temp.id('store'), pg_temp.id('o2'), 2,
  jsonb_build_object('customer_name', 'Rozh', 'city_text', 'Koya', 'delivery_fee', 7000, 'area', 'Centre',
                     'payment_method', 'cod', 'lines', jsonb_build_array(pg_temp.line('v_S', 2), pg_temp.line('v_wrap', 1))),
  gen_random_uuid()) on conflict (k) do update set v = excluded.v;
select is(pg_temp.r('o2f') #>> '{data,status}', 'draft', 'removing the phone makes it a draft again');
select is(pg_temp.r('o2f') #>> '{data,lines,1,quoted_unit_price}', '2000', 'a new line is quoted at the current price');
select is((select jsonb_build_array(before ->> 'customer_phone', after ->> 'customer_phone', after ? 'area')
             from app.audit_events where entity_id = pg_temp.id('o2') and action = 'order.update_draft'
             order by id desc limit 1),
          '["+9647501112244", null, false]'::jsonb,
          'the audit records before and after of what changed only');

-- Zone snapshot survives a zone rename.
select api.upsert_zone(pg_temp.id('store'), pg_temp.id('zone'), 1, 'Erbil city', 6000, null, gen_random_uuid()) is not null;
select is((select zone_name || ' ' || delivery_fee from app.orders where id = pg_temp.id('o1')), 'Erbil 5000',
          'renaming or repricing a zone does not change existing orders');

-- ---- Reject (OR-04) -----------------------------------------------------------------------------
select is(api.reject_draft(pg_temp.id('store'), pg_temp.id('o2'), 3, null, null, gen_random_uuid())
            #>> '{error,details,fields,reason}', 'invalid', 'a reason is required to reject');
select is(api.reject_draft(pg_temp.id('store'), pg_temp.id('o2'), 3, 'other', ' ', gen_random_uuid())
            #>> '{error,details,fields,note}', 'required', '"Other" needs a note');
insert into res select 'rej', api.reject_draft(pg_temp.id('store'), pg_temp.id('o2'), 3, 'customer_changed_mind', null,
                                               gen_random_uuid());
select is((pg_temp.r('rej') #>> '{data,status}') || ' ' || (pg_temp.r('rej') #>> '{data,closed_reason}'),
          'rejected customer_changed_mind', 'a draft can be rejected with its reason');
select is(pg_temp.stock('v_S'), 5, 'rejecting does not touch stock');
select is((api.reject_draft(pg_temp.id('store'), pg_temp.id('o2'), 4, 'duplicate', null, gen_random_uuid())
            -> 'error') - 'details' || jsonb_build_object('current', api.get_order(pg_temp.id('store'), pg_temp.id('o2')) #>> '{data,status}'),
          '{"code": "INVALID_TRANSITION", "current": "rejected"}'::jsonb, 'rejected is terminal');
select is(api.update_draft(pg_temp.id('store'), pg_temp.id('o2'), 4, '{}', gen_random_uuid()) #>> '{error,details,current_status}',
          'rejected', 'a rejected order cannot be edited');

-- ---- Lists, counts and search (OR-01) --------------------------------------------------------------
select is((api.order_summary(pg_temp.id('store')) -> 'data') - 'currency',
          '{"all": 3, "needs_approval": 2, "drafts": 0, "active": 0, "delivered": 0, "problems": 0, "closed": 1,
            "test": 0, "cod_outstanding": 0}'::jsonb, 'summary counts per filter');
select is((select jsonb_object_agg(f, api.list_orders(pg_temp.id('store'), null, f) #> '{data,total}')
             from unnest(array['all', 'needs_approval', 'closed']) f),
          '{"all": 3, "needs_approval": 2, "closed": 1}'::jsonb, 'each count equals its list''s total');
select is((select jsonb_agg(x -> 'number') from jsonb_array_elements(api.list_orders(pg_temp.id('store')) #> '{data,items}') x),
          '[1003, 1002, 1001]'::jsonb, 'newest first');
select is(api.list_orders(pg_temp.id('store'), null, 'all') #> '{data,items,2,first_item}',
          '{"name": "Beige Abaya", "variant_label": "M", "quantity": 2}'::jsonb, 'a row carries its item summary');
select is((select jsonb_object_agg(q, (select jsonb_agg(x -> 'number') from jsonb_array_elements(api.list_orders(pg_temp.id('store'), q) #> '{data,items}') x))
             from unnest(array['nzar', '0750 111 2233', '+964 750 111 2233', '1002', '١٠٠٢', 'abaya', 'ab-s']) q),
          '{"nzar": [1003, 1001], "0750 111 2233": [1003, 1001], "+964 750 111 2233": [1003, 1001], "1002": [1002],
            "١٠٠٢": [1002], "abaya": [1003, 1002, 1001], "ab-s": [1003, 1002]}'::jsonb,
          'search by name, phone in any form, number (Eastern digits too), product and SKU');
select is(api.list_orders(pg_temp.id('store'), null, 'everything') #>> '{error,code}', 'VALIDATION_FAILED',
          'unknown filters are refused');

-- ---- History (OR-11) --------------------------------------------------------------------------------
select is((select jsonb_agg(x ->> 'kind' || ':' || coalesce(x ->> 'to', '')) from jsonb_array_elements(
             api.order_history(pg_temp.id('store'), pg_temp.id('o2')) #> '{data,items}') x),
          -- (one test transaction: equal timestamps, so edits sort before status changes)
          '["edit:", "edit:", "status:draft", "status:pending_approval", "status:draft", "status:rejected"]'::jsonb,
          'history lists status changes and edits');

-- ---- Storage-level guards (Phase 3 §6.5) ---------------------------------------------------------------
select throws_ok($$ update app.orders set status = 'approved' $$, '42501', null,
                 'the seller cannot write order status directly');
select pg_temp.act_as_admin();
select throws_ok(format($$ update app.orders set status = 'approved' where id = %L $$, pg_temp.id('o2')),
                 'AS002', null, 'even a privileged write cannot approve outside the transition table (rejected → approved)');
select throws_ok(format($$ update app.orders set status = 'delivered' where id = %L $$, pg_temp.id('o1')),
                 'AS002', null, '… or reach any status BR-30 does not allow (pending → delivered)');
select throws_ok(format($$ update app.orders set status = 'approved' where id = %L $$, pg_temp.id('o1')),
                 '23514', null, 'an approved order without an approver and time is impossible');
select throws_ok(format($$ insert into app.orders (store_id, number, status, currency) values (%L, 5000, 'approved', 'IQD') $$,
                        pg_temp.id('store')),
                 'AS002', null, 'an order cannot be inserted as approved');
select throws_ok(format($$ update app.orders set status = 'draft' where id = %L $$, pg_temp.id('o2')),
                 'AS002', null, 'terminal statuses stay terminal');
select throws_ok($$ update app.order_status_events set to_status = 'approved' $$, 'AS002', null,
                 'status history cannot be rewritten');
select throws_ok($$ delete from app.order_status_events $$, 'AS002', null, '… or deleted');
select throws_ok($$ delete from app.orders $$, 'AS002', null, 'orders are never deleted (BR-32)');
select pg_temp.act_as(pg_temp.id('a'));
select is(api.upsert_product(pg_temp.id('store'), pg_temp.id('wrap'), 1,
  '{"name": "Gift wrap", "base_price": 2000, "track_stock": false, "status": "active", "option_types": ["Colour"],
    "variants": [{"option_values": ["Red"]}], "images": []}', gen_random_uuid()) #>> '{error,code}',
  'VARIANT_IN_USE', 'a variant on an order is never deleted; it can only be archived (BR-17)');

select * from finish();
rollback;
