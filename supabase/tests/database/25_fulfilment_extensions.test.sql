-- Phase 10 (roadmap R8): couriers, delivery lists, payment recording, courier settlement.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(41);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;
create function pg_temp.save(p_key text, p_value jsonb) returns jsonb language sql as $$
  insert into res values (p_key, p_value) on conflict (k) do update set v = excluded.v returning v
$$;

insert into ids values ('a', pg_temp.new_user('ful-a@example.test')), ('b', pg_temp.new_user('ful-b@example.test')),
  ('abaya', gen_random_uuid());
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store', (api.create_store('Fulfil Shop', '+9647501234567', 'IQD', 'ckb', 'Erbil',
                                                  gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'zone', (api.upsert_zone(pg_temp.id('store'), null, null, 'Erbil', 5000, null,
                                                gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v', (api.upsert_product(pg_temp.id('store'), pg_temp.id('abaya'), null,
  '{"name": "Beige Abaya", "base_price": 35000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 50}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Other Shop', '+9647501234568', 'IQD', 'ckb', 'Erbil',
                                                    gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
update app.stores set other_payment_enabled = true where id = pg_temp.id('store');

-- An approved order (COD unless p_method), remembered under p_key.
create function pg_temp.mk(p_key text, p_method text default 'cod', p_phone text default '+9647501112233')
returns void language plpgsql as $$
declare v jsonb;
begin
  perform pg_temp.act_as(pg_temp.id('a'));
  v := api.create_order(pg_temp.id('store'), jsonb_build_object('customer_name', 'Nzar Ahmad', 'customer_phone', p_phone,
         'zone_id', pg_temp.id('zone'), 'area', 'Ankawa', 'payment_method', p_method,
         'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v'), 'quantity', 1))), gen_random_uuid());
  insert into ids values (p_key, (v #>> '{data,id}')::uuid);
  perform api.approve_order(pg_temp.id('store'), pg_temp.id(p_key),
                            (select version from app.orders where id = pg_temp.id(p_key)), '{}', gen_random_uuid());
end $$;
create function pg_temp.ver(p_key text) returns integer language sql as $$ select version from app.orders where id = pg_temp.id(p_key) $$;
create function pg_temp.status(p_key text) returns text language sql as $$ select status from app.orders where id = pg_temp.id(p_key) $$;
create function pg_temp.lver(p_key text) returns integer language sql as $$ select version from app.delivery_lists where id = pg_temp.id(p_key) $$;
create function pg_temp.go(p_key text, p_to text, p_payload jsonb default '{}') returns jsonb language sql as $$
  select api.transition_order(pg_temp.id('store'), pg_temp.id(p_key), pg_temp.ver(p_key), p_to, p_payload, gen_random_uuid())
$$;
create function pg_temp.list_do(p_list text, p_action text, p_courier text, p_orders text[]) returns jsonb language sql as $$
  select api.update_delivery_list(pg_temp.id('store'), pg_temp.id(p_list), pg_temp.lver(p_list), p_action,
                                  pg_temp.id(p_courier), array(select pg_temp.id(x) from unnest(p_orders) x), gen_random_uuid())
$$;

-- ---- Couriers ------------------------------------------------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'c1', (pg_temp.save('c1', api.upsert_courier(pg_temp.id('store'), null, null, 'Karwan', '+9647701234567', true,
                                                                      gen_random_uuid())) #>> '{data,id}')::uuid;
select is(pg_temp.r('c1') #>> '{data,name}', 'Karwan', 'a courier is recorded');
select is(api.upsert_courier(pg_temp.id('store'), null, null, ' karwan ', null, true, gen_random_uuid()) #>> '{error,details,fields,name}',
          'duplicate', 'two active couriers cannot share a name');
select is(api.upsert_courier(pg_temp.id('store'), null, null, 'Dler', '0770', true, gen_random_uuid()) #>> '{error,details,fields,phone}',
          'invalid', 'the phone must be an Iraqi mobile number');
select is(api.upsert_courier(pg_temp.id('store'), pg_temp.id('c1'), 99, 'Karwan', null, true, gen_random_uuid()) #>> '{error,code}',
          'CONFLICT_VERSION', 'an update needs the current version');
insert into ids select 'c_old', (api.upsert_courier(pg_temp.id('store'), null, null, 'Old Courier', null, true, gen_random_uuid()) #>> '{data,id}')::uuid;
select api.upsert_courier(pg_temp.id('store'), pg_temp.id('c_old'), 1, 'Old Courier', null, false, gen_random_uuid());
select is(jsonb_array_length(api.list_couriers(pg_temp.id('store'), false) #> '{data,items}'), 1, 'inactive couriers are hidden by default');
select is(jsonb_array_length(api.list_couriers(pg_temp.id('store'), true) #> '{data,items}'), 2, '… and listed on request');
select pg_temp.act_as(pg_temp.id('b'));
select is(api.list_couriers(pg_temp.id('store'), true) ->> 'ok', 'false', 'another store''s user cannot see them');
select is(api.upsert_courier(pg_temp.id('store_b'), pg_temp.id('c1'), 1, 'Hijack', null, true, gen_random_uuid()) #>> '{error,code}',
          'NOT_FOUND', 'nor change them through their own store');

-- ---- Delivery lists ------------------------------------------------------------------------------------------------------
select pg_temp.mk('o1'); select pg_temp.mk('o2'); select pg_temp.mk('o3'); select pg_temp.mk('o4');
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'pend', (api.create_order(pg_temp.id('store'), jsonb_build_object('customer_name', 'X', 'customer_phone', '+9647501112299',
  'zone_id', pg_temp.id('zone'), 'area', 'Ankawa', 'payment_method', 'cod',
  'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v'), 'quantity', 1))), gen_random_uuid()) #>> '{data,id}')::uuid;
select is(api.list_delivery_lists(pg_temp.id('store'), null) #> '{data,ready}' @> jsonb_build_array(jsonb_build_object('order_id', pg_temp.id('o1'))),
          true, 'approved orders are offered for a list');
select is(api.create_delivery_list(pg_temp.id('store'), null, array[pg_temp.id('o1'), pg_temp.id('pend')], gen_random_uuid()) #>> '{error,code}',
          'INVALID_TRANSITION', 'an order still waiting for approval cannot go on a list');
insert into ids select 'l1', (pg_temp.save('l1', api.create_delivery_list(pg_temp.id('store'), null,
  array[pg_temp.id('o1'), pg_temp.id('o2'), pg_temp.id('o3')], gen_random_uuid())) #>> '{data,id}')::uuid;
select is(pg_temp.r('l1') #>> '{data,number}', '1', 'lists are numbered per store');
select is((pg_temp.r('l1') #>> '{data,stops,0,cash_to_collect}')::bigint, (select total from app.orders where id = pg_temp.id('o1')),
          'each stop shows the cash to collect');
select is(pg_temp.r('l1') #>> '{data,stops,0,phone}', '+9647501112233', '… and the customer''s phone for the courier');
select is(api.create_delivery_list(pg_temp.id('store'), null, array[pg_temp.id('o1')], gen_random_uuid()) #>> '{error,details,fields,order_ids}',
          'on_another_list', 'an order is on at most one open list');
select is(pg_temp.list_do('l1', 'hand_over', null, null) #>> '{error,details,fields,courier_id}', 'required',
          'a list is handed over to a courier');
select is(pg_temp.list_do('l1', 'set_orders', 'c_old', array['o1', 'o2', 'o3']) #>> '{error,details,fields,courier_id}', 'invalid',
          'an inactive courier cannot be chosen');
select is(pg_temp.list_do('l1', 'set_orders', 'c1', array['o1', 'o2', 'o3']) #>> '{data,courier,name}', 'Karwan', 'the courier is set');
select is(api.update_delivery_list(pg_temp.id('store'), pg_temp.id('l1'), 1, 'cancel', null, null, gen_random_uuid()) #>> '{error,code}',
          'CONFLICT_VERSION', 'a stale list version is refused');

-- All or nothing: one order cancelled meanwhile blocks the whole hand-over.
select api.cancel_order(pg_temp.id('store'), pg_temp.id('o3'), pg_temp.ver('o3'), 'customer_cancelled', null, gen_random_uuid());
select is(pg_temp.list_do('l1', 'hand_over', null, null) #>> '{error,code}', 'INCOMPLETE_ORDER', 'a list with an order no longer ready is refused');
select is(array[pg_temp.status('o1'), pg_temp.status('o2')], array['approved', 'approved'], '… and no order on it was dispatched');
select pg_temp.list_do('l1', 'set_orders', 'c1', array['o1', 'o2']);
select is(pg_temp.list_do('l1', 'hand_over', null, null) #>> '{data,status}', 'handed_over', 'the corrected list is handed over');
select is((select array_agg(status || ':' || (courier_id = pg_temp.id('c1'))::text order by number) from app.orders
            where id in (pg_temp.id('o1'), pg_temp.id('o2'))), array['dispatched:true', 'dispatched:true'],
          'every order on it is dispatched with the courier');
select is(pg_temp.list_do('l1', 'cancel', null, null) #>> '{error,code}', 'INVALID_TRANSITION', 'a handed-over list cannot change');

-- A single dispatch can name a courier, and takes the order off an open list.
insert into ids select 'l2', (api.create_delivery_list(pg_temp.id('store'), pg_temp.id('c1'), array[pg_temp.id('o4')], gen_random_uuid()) #>> '{data,id}')::uuid;
select is(pg_temp.go('o4', 'dispatched', jsonb_build_object('courier_id', pg_temp.id('c_old'))) #>> '{error,details,fields,courier_id}',
          'invalid', 'a single dispatch cannot use an inactive courier');
select is(pg_temp.go('o4', 'dispatched', jsonb_build_object('courier_id', pg_temp.id('c1'))) #>> '{data,courier,name}', 'Karwan',
          'a single dispatch records the courier');
select is((select count(*)::integer from app.delivery_list_orders where list_id = pg_temp.id('l2')), 0,
          'the dispatched order left its open list');

-- ---- Courier settlement ---------------------------------------------------------------------------------------------------
select pg_temp.go('o1', 'delivered'); select pg_temp.go('o2', 'delivered');
insert into res select 'owed', api.list_couriers(pg_temp.id('store'), false) #> '{data,items,0}';
select is((pg_temp.r('owed') ->> 'owed')::bigint,
          (select sum(total)::bigint from app.orders where id in (pg_temp.id('o1'), pg_temp.id('o2'))), 'the courier owes the cash of delivered orders');
select is((pg_temp.r('owed') ->> 'carrying_orders')::integer, 1, '… and is carrying the dispatched one');
select is(api.settle_courier(pg_temp.id('store'), pg_temp.id('c1'), (pg_temp.r('owed') ->> 'owed')::bigint + 1, gen_random_uuid())
            #>> '{error,details,fields,amount}', 'exceeds_due', 'a settlement cannot exceed what is owed');
insert into ids values ('k_settle', gen_random_uuid());
insert into res select 'settle', api.settle_courier(pg_temp.id('store'), pg_temp.id('c1'),
  (select total from app.orders where id = pg_temp.id('o1')) + 1000, pg_temp.id('k_settle'));
select is(pg_temp.r('settle') #>> '{data,allocations,0,order_id}', pg_temp.id('o1')::text, 'the oldest delivery is settled first');
select is((select array_agg(cod_collected order by number) from app.orders where id in (pg_temp.id('o1'), pg_temp.id('o2'))),
          array[(select total from app.orders where id = pg_temp.id('o1')), 1000::bigint], '… and the rest goes to the next order');
select is(api.settle_courier(pg_temp.id('store'), pg_temp.id('c1'), (select total from app.orders where id = pg_temp.id('o1')) + 1000,
                             pg_temp.id('k_settle')) #>> '{data,settlement_id}', pg_temp.r('settle') #>> '{data,settlement_id}',
          'a retried settlement (same key) is not counted twice');
select is((select count(*)::integer from app.courier_settlements where courier_id = pg_temp.id('c1')), 1, '… one settlement recorded');

-- ---- Payments (record only) -------------------------------------------------------------------------------------------
select is(api.record_payment(pg_temp.id('store'), pg_temp.id('o2'), 'fib', 1000, null, gen_random_uuid()) #>> '{error,code}',
          'INVALID_TRANSITION', 'cash-on-delivery orders are settled through the courier, not as transfers');
select pg_temp.mk('p1', 'other', '+9647509998877');
select is(api.record_payment(pg_temp.id('store'), pg_temp.id('p1'), 'zaincash', 10000, 'ZC 0750 999 8877', gen_random_uuid())
            #>> '{data,paid_total}', '10000', 'a wallet payment is recorded against an order paid "other"');
select is(api.record_payment(pg_temp.id('store'), pg_temp.id('p1'), 'bitcoin', 1, null, gen_random_uuid()) #>> '{error,details,fields,method}',
          'invalid', 'only the listed methods');
select is(api.record_payment(pg_temp.id('store'), pg_temp.id('p1'), 'fib', (select total from app.orders where id = pg_temp.id('p1')),
                             null, gen_random_uuid()) #>> '{error,details,fields,amount}', 'exceeds_due', 'payments never exceed the total');
select is(api.get_order(pg_temp.id('store'), pg_temp.id('p1')) #>> '{data,payments,0,method}', 'zaincash', 'the order shows its payments');

-- ---- Privacy, roles, account deletion ---------------------------------------------------------------------------------
select pg_temp.go('p1', 'dispatched'); select pg_temp.go('p1', 'delivered');
select api.anonymize_customer(pg_temp.id('store'), '+9647509998877', gen_random_uuid());
select pg_temp.act_as_admin();
select ok((select bool_and(reference not like '%999%8877%' and reference not like '%9998877%') from app.order_payments
            where order_id = pg_temp.id('p1')), 'anonymising the customer redacts their number in payment references');
select ok(not has_function_privilege('aisellia_ai_worker', 'api.settle_courier(uuid,uuid,bigint,uuid)', 'execute')
          and not has_function_privilege('aisellia_ai', 'api.update_delivery_list(uuid,uuid,integer,text,uuid,uuid[],uuid)', 'execute')
          and not has_table_privilege('authenticated', 'app.couriers', 'insert')
          and not has_table_privilege('authenticated', 'app.order_payments', 'update'),
          'no AI role can run these actions, and sellers write only through the functions');
select pg_temp.act_as(pg_temp.id('a'), interval '1 minute');
select api.request_account_deletion('Fulfil Shop');
select pg_temp.act_as_admin();
update app.account_deletion_requests set execute_after = now() - interval '1 minute' where user_id = pg_temp.id('a');
select internal.purge_due_account_deletions();
select is((select count(*)::integer from app.couriers where store_id = pg_temp.id('store'))
          + (select count(*)::integer from app.delivery_lists where store_id = pg_temp.id('store'))
          + (select count(*)::integer from app.order_payments where store_id = pg_temp.id('store'))
          + (select count(*)::integer from app.courier_settlements where store_id = pg_temp.id('store')), 0,
          'deleting the account purges couriers, lists, payments and settlements');

select * from finish();
rollback;
