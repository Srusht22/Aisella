-- Inventory (Phase 1 BR-14..BR-16, US-014..US-017; Phase 3 ADR-004, §6.3; Phase 2 PR-05/PR-06).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(32);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;

insert into ids values ('a', pg_temp.new_user('stock@example.test')), ('p', gen_random_uuid()),
  ('untracked', gen_random_uuid()), ('k1', gen_random_uuid());
select pg_temp.act_as((select v from ids where k = 'a'));
insert into ids select 'store', (api.create_store('Karwan Electronics', '+9647501234567', 'USD', 'en', 'Duhok',
                                                  gen_random_uuid()) #>> '{data,id}')::uuid;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.adjust(p_mode text, p_qty integer, p_reason text default 'received', p_note text default null,
                               p_expected integer default null, p_key uuid default gen_random_uuid())
returns jsonb language sql as $$
  select api.adjust_stock(pg_temp.id('store'), pg_temp.id('v'), p_mode, p_qty, p_reason, p_note, p_expected, p_key)
$$;
create function pg_temp.stock() returns integer language sql as $$
  select stock_on_hand from app.product_variants where id = pg_temp.id('v')
$$;

insert into res select 'p', api.upsert_product(pg_temp.id('store'), pg_temp.id('p'), null,
  '{"name": "USB-C Cable", "base_price": 5, "track_stock": true, "status": "active", "option_types": ["Length"],
    "variants": [{"option_values": ["1 m"], "sku": "USBC-1", "initial_stock": 5},
                 {"option_values": ["2 m"], "sku": "USBC-2", "status": "archived"}],
    "images": []}', gen_random_uuid());
insert into ids select 'v', (x ->> 'id')::uuid from res, jsonb_array_elements(v #> '{data,variants}') x
  where k = 'p' and x ->> 'label' = '1 m';
insert into ids select 'v_archived', (x ->> 'id')::uuid from res, jsonb_array_elements(v #> '{data,variants}') x
  where k = 'p' and x ->> 'label' = '2 m';
select is((select v #>> '{data,base_price}' from res where k = 'p'), '5', 'USD prices are whole dollars (D-08)');

-- ---- Add, remove, set ------------------------------------------------------------------
insert into res select 'add', pg_temp.adjust('add', 5, 'received', null, null, pg_temp.id('k1'));
select is((select v #>> '{data,previous_stock}' || '→' || (v #>> '{data,stock_on_hand}') from res where k = 'add'), '5→10',
          'Add increases stock and returns before and after');
select is((select v #>> '{data,movement,reason}' from res where k = 'add'), 'received', 'the movement carries its reason');
select is(pg_temp.adjust('add', 5, 'received', null, null, pg_temp.id('k1')), (select v from res where k = 'add'),
          'a retry with the same key replays the result');
select is(pg_temp.stock(), 10, '… and does not add the stock twice');
select is(pg_temp.adjust('add', 6, 'received', null, null, pg_temp.id('k1')) #>> '{error,code}', 'IDEMPOTENCY_KEY_REUSED',
          'the same key with another quantity is refused');

select is(pg_temp.adjust('remove', 11, 'sold_in_shop') #>> '{error,code}', 'INSUFFICIENT_STOCK',
          'stock never goes negative (BR-14)');
select is(pg_temp.adjust('remove', 11, 'sold_in_shop') #>> '{error,details,current_stock}', '10',
          '… and the answer says how many there are');
select is(pg_temp.stock(), 10, 'a refused adjustment changes nothing');
select is(pg_temp.adjust('remove', 3, 'sold_in_shop') #>> '{data,stock_on_hand}', '7', 'Remove decreases stock');
select is(pg_temp.adjust('set', 12, 'count_correction') #>> '{data,movement,delta}', '5',
          'Set count records the difference as the movement');
select is(pg_temp.adjust('set', 12, 'count_correction') #>> '{error,details,fields,quantity}', 'no_change',
          'setting the same count is refused (no empty movement)');
select is(pg_temp.adjust('set', 0, 'damaged') #>> '{data,stock_on_hand}', '0', 'Set count can reach zero');
select is(pg_temp.adjust('add', 4, 'received') #>> '{data,stock_on_hand}', '4', 'stock can be added again');

-- ---- Validation and concurrency guard ------------------------------------------------------
select is(pg_temp.adjust('add', 1, 'received', null, 9) #>> '{error,code}', 'STOCK_CHANGED',
          'an expected stock that is out of date is refused');
select is(pg_temp.adjust('add', 1, 'received', null, 9) #>> '{error,details,current_stock}', '4',
          '… with the current stock, so the sheet can refresh its preview');
select is(pg_temp.adjust('add', 1, 'received', null, 4) #>> '{data,stock_on_hand}', '5',
          'the matching expected stock is accepted');
select is(pg_temp.adjust('add', 1, 'other') #>> '{error,details,fields,note}', 'required', 'Other needs a note');
select is(pg_temp.adjust('add', 1, 'other', '  Found in the back room ') #>> '{data,movement,note}', 'Found in the back room',
          'the note is stored trimmed');
select is(pg_temp.adjust('grow', -1, 'stolen') -> 'error' -> 'details' -> 'fields',
          '{"mode": "invalid", "quantity": "out_of_range", "reason": "invalid"}'::jsonb,
          'mode, quantity and reason are validated together');
select is(pg_temp.adjust('add', 0) #>> '{error,details,fields,quantity}', 'out_of_range', 'adding zero is refused');
select is(api.adjust_stock(pg_temp.id('store'), pg_temp.id('v_archived'), 'add', 1, 'received', null, null, gen_random_uuid())
            #>> '{error,details,fields,variant}',
          'archived', 'archived variants cannot be adjusted');

insert into res select 'u', api.upsert_product(pg_temp.id('store'), pg_temp.id('untracked'), null,
  '{"name": "Repair service", "base_price": 10, "track_stock": false, "status": "active", "option_types": [],
    "variants": [{"option_values": []}], "images": []}', gen_random_uuid());
select is(api.adjust_stock(pg_temp.id('store'), (select (v #>> '{data,variants,0,id}')::uuid from res where k = 'u'),
                           'add', 1, 'received', null, null, gen_random_uuid()) #>> '{error,code}',
          'STOCK_NOT_TRACKED', 'untracked products have no stock to adjust (BR-16)');

-- ---- History (PR-06) ----------------------------------------------------------------------
insert into res select 'h', api.list_inventory_movements(pg_temp.id('store'), pg_temp.id('p'));
select is((select array_agg(x ->> 'reason' order by o) from res, jsonb_array_elements(v #> '{data,items}') with ordinality e(x, o) where k = 'h'),
          array['other', 'received', 'received', 'damaged', 'count_correction', 'sold_in_shop', 'received', 'initial_stock'],
          'history lists every movement, newest first');
select is((select (v #>> '{data,items,0,resulting_qty}')::int from res where k = 'h'), pg_temp.stock(),
          'the latest entry''s result equals the current stock (US-017)');
select is((select v #>> '{data,items,0,actor}' from res where k = 'h'), 'you', 'the actor is reported');
select is(jsonb_array_length(api.list_inventory_movements(pg_temp.id('store'), pg_temp.id('p'), null, 3) #> '{data,items}'), 3,
          'history is paged');
select is((select sum(delta)::int from app.inventory_movements where variant_id = pg_temp.id('v')), pg_temp.stock(),
          'stock equals the sum of its movements (BR-15)');

-- ---- Ledger protection and reconciliation (ADR-004) --------------------------------------
select pg_temp.act_as_admin();
select throws_ok($$ update app.inventory_movements set delta = 100 $$, 'AS002', null,
                 'movements cannot be edited, even by the database owner');
select throws_ok($$ delete from app.inventory_movements $$, 'AS002', null, 'movements cannot be deleted');
select is((select count(*)::int from internal.inventory_mismatches()), 0, 'the reconciliation finds no drift');
update app.product_variants set stock_on_hand = stock_on_hand + 1 where id = pg_temp.id('v');
select is((select count(*)::int from internal.inventory_mismatches()), 1,
          'a balance changed outside the ledger is detected by the nightly reconciliation');

select * from finish();
rollback;
