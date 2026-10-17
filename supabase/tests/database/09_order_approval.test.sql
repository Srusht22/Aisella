-- Seller approval, inventory and the order lifecycle
-- (Phase 1 BR-20..BR-23, BR-30, BR-33, BR-43, BR-44; Phase 3 §6.2–6.4; Phase 6 E §2–3; Phase 2 OR-03, OR-05..OR-10).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(91);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
create function pg_temp.save(p_key text, p_value jsonb) returns jsonb language sql as $$
  insert into res values (p_key, p_value) on conflict (k) do update set v = excluded.v returning v
$$;

insert into ids values ('a', pg_temp.new_user('approve@example.test')), ('staff', pg_temp.new_user('staff@example.test')),
  ('abaya', gen_random_uuid()), ('wrap', gen_random_uuid()), ('scarf', gen_random_uuid());
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store', (api.create_store('Nasreen Boutique', '+9647501234567', 'IQD', 'ckb', 'Erbil',
                                                  gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'zone', (api.upsert_zone(pg_temp.id('store'), null, null, 'Erbil', 5000, null,
                                                gen_random_uuid()) #>> '{data,id}')::uuid;
insert into res select 'abaya', api.upsert_product(pg_temp.id('store'), pg_temp.id('abaya'), null,
  '{"name": "Beige Abaya", "base_price": 35000, "track_stock": true, "status": "active", "option_types": ["Size"],
    "variants": [{"option_values": ["S"], "initial_stock": 5}, {"option_values": ["M"], "initial_stock": 4}],
    "images": []}', gen_random_uuid());
insert into ids select 'v_' || (x ->> 'label'), (x ->> 'id')::uuid
  from jsonb_array_elements(pg_temp.r('abaya') #> '{data,variants}') x;
insert into ids select 'v_wrap', (api.upsert_product(pg_temp.id('store'), pg_temp.id('wrap'), null,
  '{"name": "Gift wrap", "base_price": 2000, "track_stock": false, "status": "active", "option_types": [],
    "variants": [{"option_values": []}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
insert into ids select 'v_scarf', (api.upsert_product(pg_temp.id('store'), pg_temp.id('scarf'), null,
  '{"name": "Silk scarf", "base_price": 9000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 2}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;

create function pg_temp.line(p_variant text, p_qty integer) returns jsonb language sql as $$
  select jsonb_build_object('variant_id', pg_temp.id(p_variant), 'quantity', p_qty)
$$;
create function pg_temp.full_order(p_lines jsonb) returns jsonb language sql as $$
  select jsonb_build_object('customer_name', 'Nzar Ahmad', 'customer_phone', '+9647501112233',
                            'zone_id', pg_temp.id('zone'), 'area', 'Ankawa', 'payment_method', 'cod',
                            'lines', p_lines)
$$;
-- Creates a complete order and remembers its id under p_key.
create function pg_temp.mk(p_key text, p_lines jsonb) returns text language plpgsql as $$
declare v jsonb;
begin
  v := api.create_order(pg_temp.id('store'), pg_temp.full_order(p_lines), gen_random_uuid());
  insert into ids values (p_key, (v #>> '{data,id}')::uuid);
  return v #>> '{data,status}';
end $$;
create function pg_temp.ver(p_key text) returns integer language sql as $$
  select version from app.orders where id = pg_temp.id(p_key)
$$;
create function pg_temp.approve(p_key text, p_choices jsonb default '{}', p_idem uuid default gen_random_uuid())
returns jsonb language sql as $$
  select api.approve_order(pg_temp.id('store'), pg_temp.id(p_key), pg_temp.ver(p_key), p_choices, p_idem)
$$;
create function pg_temp.go(p_key text, p_to text, p_payload jsonb default '{}') returns jsonb language sql as $$
  select api.transition_order(pg_temp.id('store'), pg_temp.id(p_key), pg_temp.ver(p_key), p_to, p_payload, gen_random_uuid())
$$;
create function pg_temp.stock(p_variant text) returns integer language sql as $$
  select stock_on_hand from app.product_variants where id = pg_temp.id(p_variant)
$$;
create function pg_temp.status(p_key text) returns text language sql as $$
  select status from app.orders where id = pg_temp.id(p_key)
$$;
create function pg_temp.moves(p_key text) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_array(reason, delta, resulting_qty) order by id), '[]'::jsonb)
    from app.inventory_movements where order_id = pg_temp.id(p_key)
$$;

select is(pg_temp.mk('o1', jsonb_build_array(pg_temp.line('v_M', 2), pg_temp.line('v_wrap', 1))), 'pending_approval',
          'setup: an order waiting for approval');

-- ---- The approval gate: who may approve (BR-30 "owner only"; Phase 3 T5) -----------------------
select pg_temp.act_as_anon();
select throws_ok(format($$ select api.approve_order(%L, %L, 1, '{}', gen_random_uuid()) $$, pg_temp.id('store'), pg_temp.id('o1')),
                 '42501', null, 'anon cannot call approval');
select pg_temp.act_as_admin();
set local role service_role;
select throws_ok(format($$ select api.approve_order(%L, %L, 1, '{}', gen_random_uuid()) $$, pg_temp.id('store'), pg_temp.id('o1')),
                 '42501', null, 'service_role (the backend or the AI) cannot call approval');
reset role;
-- A token that claims service_role but reaches the function anyway is still refused.
select set_config('request.jwt.claims', json_build_object('sub', pg_temp.id('a'), 'role', 'service_role')::text, true);
set local role authenticated;
select is(api.approve_order(pg_temp.id('store'), pg_temp.id('o1'), 1, '{}', gen_random_uuid()) #>> '{error,code}', 'FORBIDDEN',
          'a non-end-user caller is FORBIDDEN even with the owner''s id');
select pg_temp.act_as_admin();
insert into app.store_members (store_id, user_id, role, permissions)
values (pg_temp.id('store'), pg_temp.id('staff'), 'staff', '{"orders.approve": true, "orders.create_draft": true}');
select pg_temp.act_as(pg_temp.id('staff'));
select is(api.approve_order(pg_temp.id('store'), pg_temp.id('o1'), 1, '{}', gen_random_uuid()) #>> '{error,code}', 'FORBIDDEN',
          'staff cannot approve, even with an approve permission (owner only in P0)');
select is(api.cancel_order(pg_temp.id('store'), pg_temp.id('o1'), 1, 'duplicate', null, gen_random_uuid()) #>> '{error,code}',
          'FORBIDDEN', 'staff without a permission is refused');
select pg_temp.act_as_admin();
insert into ids values ('unverified', gen_random_uuid());
insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data)
values (pg_temp.id('unverified'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'unverified@example.test', '{"terms_version": "2026-10"}');
select pg_temp.act_as(pg_temp.id('unverified'));
insert into ids select 'store_u', (api.create_store('Unverified Shop', '+9647701234567', 'IQD', 'ckb', 'Duhok',
                                                    gen_random_uuid()) #>> '{data,id}')::uuid;
insert into res select 'pu', api.upsert_product(pg_temp.id('store_u'), gen_random_uuid(), null,
  '{"name": "Mug", "base_price": 3000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 3}], "images": []}', gen_random_uuid());
insert into res select 'ou', api.create_order(pg_temp.id('store_u'), jsonb_build_object(
  'customer_name', 'Dara', 'customer_phone', '+9647501110000', 'city_text', 'Duhok', 'delivery_fee', 0, 'area', 'Centre',
  'payment_method', 'cod', 'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.r('pu') #>> '{data,variants,0,id}',
                                                                       'quantity', 1))), gen_random_uuid());
select is(api.approve_order(pg_temp.id('store_u'), (pg_temp.r('ou') #>> '{data,id}')::uuid, 1, '{}', gen_random_uuid())
            #>> '{error,code}', 'EMAIL_NOT_VERIFIED', 'an owner without a confirmed email cannot approve');
select pg_temp.act_as(pg_temp.id('a'));
select is(pg_temp.status('o1'), 'pending_approval', 'none of the refused callers changed the order');

-- ---- Approval (Phase 3 §6.2) ---------------------------------------------------------------------
insert into ids values ('k1', gen_random_uuid());
insert into res select 'a1', pg_temp.approve('o1', '{}', pg_temp.id('k1'));
select is(pg_temp.r('a1') #>> '{data,status}', 'approved', 'the owner approves a pending order');
select is(pg_temp.r('a1') #>> '{data,approved_by}', 'you', '… recorded as approved by the seller');
select ok((pg_temp.r('a1') #>> '{data,approved_at}') is not null, '… with the time');
select is(pg_temp.stock('v_M'), 2, 'approval deducts stock (4 − 2) (BR-20)');
select is(pg_temp.r('a1') #> '{data,stock_after}',
          jsonb_build_array(jsonb_build_object('item_id', pg_temp.r('a1') #> '{data,lines,0,id}', 'variant_id', pg_temp.id('v_M'),
                                               'name', 'Beige Abaya', 'label', 'M', 'before', 4, 'after', 2)),
          'the answer lists the stock change, exactly as recorded (OR-03)');
select is(pg_temp.moves('o1'), '[["order_approved", -2, 2]]'::jsonb,
          'one movement, reason order_approved, linked to the order; none for the untracked line (BR-16)');
select is((select jsonb_agg(jsonb_build_array(x -> 'approved_unit_price', x -> 'stock_deducted'))
             from jsonb_array_elements(pg_temp.r('a1') #> '{data,lines}') x),
          '[[35000, 2], [2000, 0]]'::jsonb, 'approved prices are stored per line');
select is(pg_temp.r('a1') #>> '{data,payment,cod_due}', '77000', 'cash due on delivery = total (BR-43)');
select ok((select currency_locked_at is not null from app.stores where id = pg_temp.id('store')),
          'the store currency is locked by the first approval');
select is((pg_temp.r('a1') #> '{data,events,1}') - 'created_at',
          '{"from": "pending_approval", "to": "approved", "actor": "you", "reason": null, "note": null}'::jsonb,
          'approval is a status event by the seller');
select is(api.approve_order(pg_temp.id('store'), pg_temp.id('o1'), 1, '{}', pg_temp.id('k1')), pg_temp.r('a1'),
          'a retried approval (same key) replays the result (BR-22)');
select is(pg_temp.moves('o1'), '[["order_approved", -2, 2]]'::jsonb, '… without a second deduction');
select is((pg_temp.approve('o1') -> 'error') - 'details' || jsonb_build_object('current',
            pg_temp.approve('o1') #>> '{error,details,current_status}'),
          '{"code": "INVALID_TRANSITION", "current": "approved"}'::jsonb,
          'a second approval (new key, other device) reports the current status and changes nothing');
select is(pg_temp.stock('v_M'), 2, '… stock is deducted once');

-- ---- Refusals: everything or nothing (BR-21) ---------------------------------------------------------
insert into res select 'd', api.create_order(pg_temp.id('store'), '{"customer_name": "Draft only"}', gen_random_uuid());
select is(api.approve_order(pg_temp.id('store'), (pg_temp.r('d') #>> '{data,id}')::uuid, 1, '{}', gen_random_uuid())
            #>> '{error,code}', 'INCOMPLETE_ORDER', 'a draft cannot be approved');
select is(pg_temp.mk('o2', jsonb_build_array(pg_temp.line('v_S', 6))), 'pending_approval', 'setup: 6 of S, 5 in stock');
select is(api.approve_order(pg_temp.id('store'), pg_temp.id('o2'), 99, '{}', gen_random_uuid()) #>> '{error,code}',
          'CONFLICT_VERSION', 'approving an out-of-date version is refused');
select is((pg_temp.approve('o2') #> '{error,details,lines,0}') - 'item_id',
          '{"requested": 6, "available": 5}'::jsonb, 'INSUFFICIENT_STOCK reports requested and available');
select ok(pg_temp.status('o2') = 'pending_approval' and pg_temp.stock('v_S') = 5 and pg_temp.moves('o2') = '[]',
          '… and nothing changed');
select is(pg_temp.mk('o3', jsonb_build_array(pg_temp.line('v_S', 1), pg_temp.line('v_scarf', 3))), 'pending_approval',
          'setup: one line fits, one does not');
select is(pg_temp.approve('o3') #>> '{error,code}', 'INSUFFICIENT_STOCK', 'one short line refuses the whole approval');
select is(pg_temp.stock('v_S'), 5, '… the line that fitted was not deducted either');
select is(pg_temp.mk('o4', jsonb_build_array(pg_temp.line('v_scarf', 1))), 'pending_approval', 'setup: a scarf order');
select is(api.set_product_status(pg_temp.id('store'), pg_temp.id('scarf'), 1, 'inactive') #>> '{data,status}', 'inactive',
          'setup: the scarf becomes inactive after the order was drafted');
select is((pg_temp.approve('o4') #> '{error,details,lines,0}') - 'item_id', '{"reason": "inactive"}'::jsonb,
          'LINE_UNAVAILABLE for a product made inactive');
select is(api.set_product_status(pg_temp.id('store'), pg_temp.id('scarf'), 2, 'active') #>> '{data,status}', 'active', 'setup: restored');
select is(pg_temp.mk('o5', jsonb_build_array(pg_temp.line('v_wrap', 1))), 'pending_approval', 'setup: a wrap order');
select pg_temp.act_as_admin();
update app.product_variants set available = false where id = pg_temp.id('v_wrap');
select pg_temp.act_as(pg_temp.id('a'));
select is((pg_temp.approve('o5') #> '{error,details,lines,0}') - 'item_id', '{"reason": "unavailable"}'::jsonb,
          'LINE_UNAVAILABLE for an untracked product marked unavailable');
select pg_temp.act_as_admin();
update app.product_variants set available = true where id = pg_temp.id('v_wrap');
select pg_temp.act_as(pg_temp.id('a'));

-- ---- Price changed since the quote (BR-23) ----------------------------------------------------------
select is(pg_temp.mk('o6', jsonb_build_array(pg_temp.line('v_S', 1))) || pg_temp.mk('o7', jsonb_build_array(pg_temp.line('v_S', 1))),
          'pending_approvalpending_approval', 'setup: two orders quoted at 35,000');
select pg_temp.act_as_admin();
update app.product_variants set price_override = 38000 where id = pg_temp.id('v_S');
select pg_temp.act_as(pg_temp.id('a'));
select is((pg_temp.approve('o6') #> '{error,details,items,0}') - 'item_id', '{"quoted": 35000, "current": 38000}'::jsonb,
          'PRICE_CHANGED shows both prices; the seller must choose');
select is(pg_temp.stock('v_S'), 5, '… nothing was deducted');
select is(pg_temp.approve('o6', '{"x": "cheapest"}') #>> '{error,details,fields,price_choices}', 'invalid',
          'a price choice is quoted or current only');
select is(pg_temp.approve('o6', jsonb_build_object((select id from app.order_items where order_id = pg_temp.id('o6'))::text, 'quoted'))
            #>> '{data,total}', '40000', 'choosing the quoted price approves at 35,000');
select is(pg_temp.approve('o7', jsonb_build_object((select id from app.order_items where order_id = pg_temp.id('o7'))::text, 'current'))
            #>> '{data,lines,0,approved_unit_price}', '38000', 'choosing the current price approves at 38,000');
select is(pg_temp.stock('v_S'), 3, 'both deducted');

-- ---- Fulfilment (BR-30, OR-08) ----------------------------------------------------------------------
select is(pg_temp.go('o1', 'delivered') #>> '{error,code}', 'INVALID_TRANSITION', 'approved cannot jump to delivered');
select is(pg_temp.go('o1', 'approved') #>> '{error,details,fields,to}', 'invalid',
          'there is no generic set-status: approved is not a fulfilment step');
select is(pg_temp.go('o1', 'processing') #>> '{data,status}', 'processing', 'Mark as preparing');
select is(pg_temp.go('o1', 'dispatched', '{"courier_note": "Karwan, white van"}') #>> '{data,delivery,courier_note}',
          'Karwan, white van', 'Mark out for delivery, with the courier');
select is(api.cancel_order(pg_temp.id('store'), pg_temp.id('o1'), pg_temp.ver('o1'), 'customer_cancelled', null, gen_random_uuid())
            #>> '{error,code}', 'INVALID_TRANSITION', 'cancel is impossible after dispatch (OR-09)');
select is(api.edit_approved_order(pg_temp.id('store'), pg_temp.id('o1'), pg_temp.ver('o1'), pg_temp.full_order('[]'), gen_random_uuid())
            #>> '{error,code}', 'INVALID_TRANSITION', 'items cannot be edited after dispatch (BR-33)');
select is(pg_temp.go('o1', 'delivery_failed') #>> '{error,details,fields,reason}', 'invalid', 'a failed delivery needs a reason');
select is(pg_temp.go('o1', 'delivery_failed', '{"reason": "refused"}') #>> '{data,failure_reason}', 'refused', 'Delivery failed');
select is(pg_temp.go('o1', 'dispatched') #>> '{data,status}', 'dispatched', 'Try again');
select is(pg_temp.go('o1', 'delivered', '{"cod_collected": 80000}') #>> '{error,details,fields,cod_collected}', 'exceeds_due',
          'cash collected cannot exceed what is due');
select is((pg_temp.go('o1', 'delivered', '{"cod_collected": 50000}') #> '{data,payment}') - 'method' - 'note',
          '{"cod_due": 77000, "cod_collected": 50000, "cod_outstanding": 27000}'::jsonb, 'Mark delivered with part of the cash');
select is(api.order_summary(pg_temp.id('store')) #>> '{data,problems}', '1', 'a delivered order with cash outstanding is a problem');
select is(pg_temp.go('o1', 'processing') #>> '{error,details,current_status}', 'delivered', 'delivered is terminal for fulfilment');
select is(api.record_cod(pg_temp.id('store'), pg_temp.id('o1'), 30000, gen_random_uuid()) #>> '{error,details,fields,amount}',
          'exceeds_due', 'Record cash: at most what is outstanding');
select is(api.record_cod(pg_temp.id('store'), pg_temp.id('o1'), 27000, gen_random_uuid()) #>> '{data,payment,cod_outstanding}',
          '0', 'Record cash settles the rest');
select is(pg_temp.stock('v_M') || '/' || jsonb_array_length(pg_temp.moves('o1')), '2/1', 'fulfilment never moves stock');

-- ---- Returns (OR-08 "Mark returned") ----------------------------------------------------------------
select is(pg_temp.go('o6', 'dispatched') #>> '{data,status}', 'dispatched', 'setup: o6 out for delivery');
select is(api.record_return(pg_temp.id('store'), pg_temp.id('o6'), pg_temp.ver('o6'), '[]', null, gen_random_uuid())
            #>> '{error,details,fields,lines}', 'every_line_decided', 'every line needs a restock or write-off decision');
insert into res select 'ret', api.record_return(pg_temp.id('store'), pg_temp.id('o6'), pg_temp.ver('o6'),
  jsonb_build_array(jsonb_build_object('item_id', (select id from app.order_items where order_id = pg_temp.id('o6')),
                                       'restock_qty', 1, 'writeoff_qty', 0)), 'Wrong size', gen_random_uuid());
select is((pg_temp.r('ret') #>> '{data,status}') || ' ' || (pg_temp.r('ret') #>> '{data,payment,cod_due}'), 'returned 0',
          'returned, with nothing due (BR-44)');
select is(pg_temp.stock('v_S') || ' ' || pg_temp.moves('o6')::text, '4 [["order_approved", -1, 4], ["order_returned_restock", 1, 4]]',
          'the restocked unit is back with its own movement');
select is(api.record_return(pg_temp.id('store'), pg_temp.id('o6'), pg_temp.ver('o6'), '[]', null, gen_random_uuid()) #>> '{error,code}',
          'INVALID_TRANSITION', 'returned is terminal (no second restock)');
select is(pg_temp.go('o7', 'dispatched') #>> '{data,status}', 'dispatched', 'setup: o7 out for delivery');
select is(api.record_return(pg_temp.id('store'), pg_temp.id('o7'), pg_temp.ver('o7'),
  jsonb_build_array(jsonb_build_object('item_id', (select id from app.order_items where order_id = pg_temp.id('o7')),
                                       'restock_qty', 0, 'writeoff_qty', 1)), null, gen_random_uuid()) #> '{data,lines,0,return}',
          '{"restock_qty": 0, "writeoff_qty": 1}'::jsonb, 'a written-off unit is recorded');
select is(pg_temp.stock('v_S') || ' ' || jsonb_array_length(pg_temp.moves('o7')), '4 1', '… and does not come back to stock');

-- ---- Cancel (OR-09): restock exactly once -----------------------------------------------------------
select is(pg_temp.mk('o8', jsonb_build_array(pg_temp.line('v_M', 1), pg_temp.line('v_wrap', 1))), 'pending_approval', 'setup');
select is(pg_temp.approve('o8') #>> '{data,status}', 'approved', 'setup: approved (M 2 → 1)');
select is(api.cancel_order(pg_temp.id('store'), pg_temp.id('o8'), pg_temp.ver('o8'), null, null, gen_random_uuid())
            #>> '{error,details,fields,reason}', 'invalid', 'cancelling needs a reason');
insert into ids values ('kc', gen_random_uuid());
insert into res select 'c', api.cancel_order(pg_temp.id('store'), pg_temp.id('o8'), pg_temp.ver('o8'), 'customer_cancelled', null,
                                             pg_temp.id('kc'));
select is((pg_temp.r('c') #>> '{data,status}') || ' ' || (pg_temp.r('c') #>> '{data,payment,cod_due}'), 'cancelled 0',
          'cancelled, with nothing due');
select is(pg_temp.stock('v_M') || ' ' || pg_temp.moves('o8')::text, '2 [["order_approved", -1, 1], ["order_cancelled", 1, 2]]',
          'stock comes back with an order_cancelled movement');
select is(api.cancel_order(pg_temp.id('store'), pg_temp.id('o8'), 2, 'customer_cancelled', null, pg_temp.id('kc')), pg_temp.r('c'),
          'a retried cancel replays');
select is(api.cancel_order(pg_temp.id('store'), pg_temp.id('o8'), pg_temp.ver('o8'), 'duplicate', null, gen_random_uuid())
            #>> '{error,code}', 'INVALID_TRANSITION', 'a cancelled order cannot be cancelled again');
select is(pg_temp.stock('v_M'), 2, 'the restock happened exactly once');

-- ---- Edit an approved order (BR-33, OR-06 edit mode) ----------------------------------------------------
select is(pg_temp.mk('o9', jsonb_build_array(pg_temp.line('v_M', 1))) || (pg_temp.approve('o9') #>> '{data,status}'),
          'pending_approvalapproved', 'setup: approved (M 2 → 1)');
create function pg_temp.edit(p_lines jsonb, p_extra jsonb default '{}') returns jsonb language sql as $$
  select api.edit_approved_order(pg_temp.id('store'), pg_temp.id('o9'), pg_temp.ver('o9'), pg_temp.full_order(p_lines) || p_extra,
                                 gen_random_uuid())
$$;
select is((pg_temp.edit(jsonb_build_array(pg_temp.line('v_M', 2))) #> '{data,stock_diff,0}') - 'variant_id' - 'name',
          '{"label": "M", "delta": -1, "before": 1, "after": 0}'::jsonb, 'an increase takes the difference from stock');
select is(pg_temp.edit(jsonb_build_array(pg_temp.line('v_M', 1), pg_temp.line('v_S', 1))) #> '{data,lines}' -> 1 -> 'approved_unit_price',
          '38000'::jsonb, 'a new line is priced at the current catalog price');
select is(pg_temp.stock('v_M') || ' ' || pg_temp.stock('v_S'), '1 3', '… a decrease gives back, a new line takes');
select is((pg_temp.edit(jsonb_build_array(pg_temp.line('v_M', 5), pg_temp.line('v_S', 1))) #> '{error,details,lines,0}') - 'variant_id',
          '{"index": 0, "requested": 4, "available": 1}'::jsonb, 'an increase beyond stock is refused per line');
select is((pg_temp.edit(jsonb_build_array(pg_temp.line('v_M', 1)), '{"customer_phone": null}') #>> '{error,code}') || ' ' ||
          pg_temp.stock('v_S'), 'INCOMPLETE_ORDER 3', 'an approved order must stay complete; nothing changed');
select is(pg_temp.edit(jsonb_build_array(pg_temp.line('v_M', 1)), '{"discount": 1000}') #>> '{data,payment,cod_due}', '39000',
          'removing a line and adding a discount recomputes total and cash due');
select is(pg_temp.stock('v_S') || ' ' || (select approved_unit_price from app.order_items where order_id = pg_temp.id('o9')),
          '4 35000', 'the removed line is restocked; the kept line keeps its approved price');
select is((select after -> 'stock_diff' -> 0 ->> 'delta' from app.audit_events
            where entity_id = pg_temp.id('o9') and action = 'order.edit' order by id desc limit 1),
          '1', 'edits are audited with their stock difference');

-- ---- Confirmation and notes (OR-10, BR-46) ----------------------------------------------------------------
select is(api.mark_confirmation_sent(pg_temp.id('store'), (pg_temp.r('d') #>> '{data,id}')::uuid) #>> '{error,code}',
          'INVALID_TRANSITION', 'no confirmation for a draft (BR-04)');
insert into res select 'm', api.mark_confirmation_sent(pg_temp.id('store'), pg_temp.id('o9'));
select ok((pg_temp.r('m') #>> '{data,confirmation_marked_sent_at}') is not null, '"I sent this" is recorded as the seller''s statement');
select is(api.mark_confirmation_sent(pg_temp.id('store'), pg_temp.id('o9')) #>> '{data,confirmation_marked_sent_at}',
          pg_temp.r('m') #>> '{data,confirmation_marked_sent_at}', '… once');
select is(api.update_order_note(pg_temp.id('store'), pg_temp.id('o8'), pg_temp.ver('o8'), 'Refunded nothing') #>> '{data,internal_note}',
          'Refunded nothing', 'the internal note stays editable after the order closes');

-- ---- Invariants (Phase 6 E §3) --------------------------------------------------------------------------
select is(api.list_inventory_movements(pg_temp.id('store'), pg_temp.id('abaya'), pg_temp.id('v_M'), 1) #> '{data,items,0}' ->> 'order_number',
          '1010', 'stock history names the order');
select pg_temp.act_as_admin();
select is((select count(*)::integer from internal.inventory_mismatches()), 0, 'stock = Σ movements for every variant');
select is((select count(*)::integer from internal.order_stock_mismatches()), 0,
          'units held by order lines = their order movements, for every order');

select * from finish();
rollback;
