-- Order tenant isolation: two sellers (Phase 3 authorization §3, T-01/T-02; Phase 1 BR-61).
-- Seller B must never read, change or reference seller A's orders, through A's store id or B's own.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(30);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.r(p text) returns jsonb language sql as $$ select v from res where k = p $$;

insert into ids values ('a', pg_temp.new_user('seller-a@example.test')), ('b', pg_temp.new_user('seller-b@example.test'));

-- Seller A: a catalog, a zone, an approved order and a pending one.
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'store_a', (api.create_store('Shop A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'zone_a', (api.upsert_zone(pg_temp.id('store_a'), null, null, 'Erbil', 5000, null, gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v_a', (api.upsert_product(pg_temp.id('store_a'), gen_random_uuid(), null,
  '{"name": "Abaya A", "base_price": 35000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 5}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;
create function pg_temp.order_a() returns jsonb language sql as $$
  select jsonb_build_object('customer_name', 'Customer of A', 'customer_phone', '+9647501112233', 'zone_id', pg_temp.id('zone_a'),
                            'area', 'Ankawa', 'payment_method', 'cod',
                            'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_a'), 'quantity', 1)))
$$;
insert into ids select 'oa', (api.create_order(pg_temp.id('store_a'), pg_temp.order_a(), gen_random_uuid()) #>> '{data,id}')::uuid;
select is(api.approve_order(pg_temp.id('store_a'), pg_temp.id('oa'), 1, '{}', gen_random_uuid()) #>> '{data,status}', 'approved',
          'setup: A has an approved order');
insert into ids select 'pa', (api.create_order(pg_temp.id('store_a'), pg_temp.order_a(), gen_random_uuid()) #>> '{data,id}')::uuid;
insert into res select 'oa_before', api.get_order(pg_temp.id('store_a'), pg_temp.id('oa')) -> 'data';
insert into res select 'pa_before', api.get_order(pg_temp.id('store_a'), pg_temp.id('pa')) -> 'data';

-- Seller B: own store and catalog.
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'store_b', (api.create_store('Shop B', '+9647701234567', 'IQD', 'ckb', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;
insert into ids select 'v_b', (api.upsert_product(pg_temp.id('store_b'), gen_random_uuid(), null,
  '{"name": "Mug B", "base_price": 3000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 5}], "images": []}', gen_random_uuid()) #>> '{data,variants,0,id}')::uuid;

-- Every order function, with A's order through A's store id and through B's own store id.
create function pg_temp.attempts(p_store uuid, p_order uuid) returns jsonb language sql as $$
  select jsonb_build_object(
    'get', api.get_order(p_store, p_order) #>> '{error,code}',
    'history', api.order_history(p_store, p_order) #>> '{error,code}',
    'update_draft', api.update_draft(p_store, p_order, 1, '{}', gen_random_uuid()) #>> '{error,code}',
    'approve', api.approve_order(p_store, p_order, 1, '{}', gen_random_uuid()) #>> '{error,code}',
    'reject', api.reject_draft(p_store, p_order, 1, 'duplicate', null, gen_random_uuid()) #>> '{error,code}',
    'edit', api.edit_approved_order(p_store, p_order, 2, '{}', gen_random_uuid()) #>> '{error,code}',
    'cancel', api.cancel_order(p_store, p_order, 2, 'duplicate', null, gen_random_uuid()) #>> '{error,code}',
    'transition', api.transition_order(p_store, p_order, 2, 'processing', '{}', gen_random_uuid()) #>> '{error,code}',
    'return', api.record_return(p_store, p_order, 2, '[]', null, gen_random_uuid()) #>> '{error,code}',
    'cod', api.record_cod(p_store, p_order, 1, gen_random_uuid()) #>> '{error,code}',
    'confirmation', api.mark_confirmation_sent(p_store, p_order) #>> '{error,code}',
    'note', api.update_order_note(p_store, p_order, 2, 'mine now') #>> '{error,code}')
$$;
create function pg_temp.all_not_found(p jsonb) returns boolean language sql as $$
  select not exists (select 1 from jsonb_each_text(p) e where e.value is distinct from 'NOT_FOUND')
$$;
insert into res select 'via_a', pg_temp.attempts(pg_temp.id('store_a'), pg_temp.id('oa'));
insert into res select 'via_b', pg_temp.attempts(pg_temp.id('store_b'), pg_temp.id('oa'));
insert into res select 'via_a_pending', pg_temp.attempts(pg_temp.id('store_a'), pg_temp.id('pa'));
insert into res select 'via_b_pending', pg_temp.attempts(pg_temp.id('store_b'), pg_temp.id('pa'));
select ok(pg_temp.all_not_found(pg_temp.r('via_a')), 'B gets NOT_FOUND from all 12 order functions on A''s approved order via A''s store');
select ok(pg_temp.all_not_found(pg_temp.r('via_b')), '… and via B''s own store id');
select ok(pg_temp.all_not_found(pg_temp.r('via_a_pending')), 'B cannot read, approve, edit or reject A''s pending order via A''s store');
select ok(pg_temp.all_not_found(pg_temp.r('via_b_pending')), '… or via B''s own store');
select is(jsonb_object_keys_count, 12, 'all 12 order functions were attempted')
  from (select count(*)::integer as jsonb_object_keys_count from jsonb_object_keys(pg_temp.r('via_a'))) c;
select is(api.list_orders(pg_temp.id('store_a')) #>> '{error,code}', 'NOT_FOUND', 'B cannot list A''s orders');
select is(api.order_summary(pg_temp.id('store_a')) #>> '{error,code}', 'NOT_FOUND', 'B cannot count A''s orders');
select is(api.list_orders(pg_temp.id('store_b')) #>> '{data,total}', '0', 'B''s own list does not include A''s orders');
select is(api.list_orders(pg_temp.id('store_b'), 'Customer of A') #>> '{data,total}', '0', '… not even by searching for them');
select is(api.create_order(pg_temp.id('store_a'), '{}', gen_random_uuid()) #>> '{error,code}', 'NOT_FOUND',
          'B cannot create an order in A''s store');
select is(api.create_order(pg_temp.id('store_b'), jsonb_build_object('lines',
            jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_a'), 'quantity', 1))), gen_random_uuid())
            #>> '{error,details,fields,lines.0.variant_id}',
          'unknown', 'B cannot put A''s product on B''s order (it reads as unknown)');
select is(api.create_order(pg_temp.id('store_b'), jsonb_build_object('zone_id', pg_temp.id('zone_a')), gen_random_uuid())
            #>> '{error,details,fields,zone_id}', 'invalid', 'B cannot use A''s delivery zone');
insert into res select 'ob', api.create_order(pg_temp.id('store_b'), jsonb_build_object('customer_name', 'Customer of B',
  'lines', jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_b'), 'quantity', 1))), gen_random_uuid());
select is(pg_temp.r('ob') #>> '{data,number}', '1001', 'order numbers are per store (B starts at #1001 too)');
select is(api.update_draft(pg_temp.id('store_b'), (pg_temp.r('ob') #>> '{data,id}')::uuid, 1, jsonb_build_object('lines',
            jsonb_build_array(jsonb_build_object('variant_id', pg_temp.id('v_a'), 'quantity', 1))), gen_random_uuid())
            #>> '{error,details,fields,lines.0.variant_id}', 'unknown', '… nor add A''s product by editing B''s draft');

-- RLS and grants (defence in depth).
select is((select count(*)::integer from app.orders), 1, 'RLS: B sees only B''s orders');
select is((select count(*)::integer from app.order_items where store_id = pg_temp.id('store_a')), 0, 'RLS: none of A''s lines');
select is((select count(*)::integer from app.order_status_events where store_id = pg_temp.id('store_a')), 0, 'RLS: none of A''s history');
select is((select count(*)::integer from app.inventory_movements where order_id = pg_temp.id('oa')), 0,
          'RLS: none of A''s order movements');
select throws_ok(format($$ update app.orders set customer_name = 'x' where id = %L $$, pg_temp.id('oa')), '42501', null,
                 'B cannot write orders directly');
select throws_ok(format($$ insert into app.order_items (store_id, order_id, variant_id, product_id, name_snapshot, quantity)
                           values (%L, %L, %L, null, 'x', 1) $$, pg_temp.id('store_a'), pg_temp.id('oa'), pg_temp.id('v_a')),
                 '42501', null, 'B cannot insert lines directly');
select throws_ok($$ select * from app.order_transitions $$, '42501', null, 'the transition table is not readable by clients');

-- A's orders and stock are exactly as before.
select pg_temp.act_as(pg_temp.id('a'));
select is(api.get_order(pg_temp.id('store_a'), pg_temp.id('oa')) -> 'data', pg_temp.r('oa_before'), 'A''s approved order is unchanged');
select is(api.get_order(pg_temp.id('store_a'), pg_temp.id('pa')) -> 'data', pg_temp.r('pa_before'), 'A''s pending order is unchanged');
select is((select stock_on_hand from app.product_variants where id = pg_temp.id('v_a')), 4, 'A''s stock is unchanged (5 − 1 approved)');
select is(api.get_order(pg_temp.id('store_a'), (pg_temp.r('ob') #>> '{data,id}')::uuid) #>> '{error,code}', 'NOT_FOUND',
          'and A cannot see B''s order either');

-- Anonymous callers.
select pg_temp.act_as_anon();
select throws_ok(format($$ select api.get_order(%L, %L) $$, pg_temp.id('store_a'), pg_temp.id('oa')), '42501', null,
                 'anon cannot read orders');
select throws_ok(format($$ select api.create_order(%L, '{}', gen_random_uuid()) $$, pg_temp.id('store_a')), '42501', null,
                 'anon cannot create orders');
select throws_ok($$ select count(*) from app.orders $$, '42501', null, 'anon cannot select orders');
select pg_temp.act_as_admin();
select is((select count(*)::integer from app.orders where store_id = pg_temp.id('store_a')), 2, 'A still has exactly its two orders');

select * from finish();
rollback;
