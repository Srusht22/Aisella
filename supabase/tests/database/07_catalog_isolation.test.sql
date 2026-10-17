-- Catalog and media tenant isolation (Phase 3 NT-01..NT-07, T-01, T-06): seller B can neither
-- read nor change seller A's products, stock, history or images, whatever ids B sends.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(32);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;

insert into ids values ('a', pg_temp.new_user('a@example.test')), ('b', pg_temp.new_user('b@example.test')),
  ('pa', gen_random_uuid()), ('pb', gen_random_uuid());

-- Seller A: a store, a product with stock and an image.
select pg_temp.act_as(pg_temp.id('a'));
insert into ids select 'sa', (api.create_store('Store A', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{data,id}')::uuid;
select pg_temp.act_as_admin();
insert into storage.objects (bucket_id, name) values
  ('store-media', pg_temp.id('sa') || '/products/' || pg_temp.id('pa') || '/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg'),
  ('store-media', pg_temp.id('sa') || '/products/' || pg_temp.id('pa') || '/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg');
select pg_temp.act_as(pg_temp.id('a'));
insert into res select 'pa', api.upsert_product(pg_temp.id('sa'), pg_temp.id('pa'), null, jsonb_build_object(
  'name', 'Secret Abaya', 'base_price', 35000, 'track_stock', true, 'status', 'active', 'option_types', '[]'::jsonb,
  'variants', '[{"option_values": [], "sku": "SECRET-1", "initial_stock": 7}]'::jsonb,
  'images', jsonb_build_array(pg_temp.id('sa') || '/products/' || pg_temp.id('pa') || '/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg')),
  gen_random_uuid());
select is((select v ->> 'ok' from res where k = 'pa'), 'true', 'A created a product with an image');
insert into ids select 'va', (v #>> '{data,variants,0,id}')::uuid from res where k = 'pa';

-- Seller B with their own store.
select pg_temp.act_as(pg_temp.id('b'));
insert into ids select 'sb', (api.create_store('Store B', '+9647701234567', 'IQD', 'ckb', 'Duhok', gen_random_uuid()) #>> '{data,id}')::uuid;

-- ---- Reads ---------------------------------------------------------------------------------
select is(api.list_products(pg_temp.id('sa')) #>> '{error,code}', 'NOT_FOUND', 'NT-01 B cannot list A''s catalog');
select is(api.get_product(pg_temp.id('sa'), pg_temp.id('pa')) #>> '{error,code}', 'NOT_FOUND', 'NT-01 B cannot read A''s product');
select is(api.get_product(pg_temp.id('sb'), pg_temp.id('pa')) #>> '{error,code}', 'NOT_FOUND',
          'NT-06 B cannot read A''s product through B''s own store id');
select is(api.catalog_summary(pg_temp.id('sa')) #>> '{error,code}', 'NOT_FOUND', 'NT-01 B cannot read A''s catalog summary');
select is(api.list_inventory_movements(pg_temp.id('sa'), pg_temp.id('pa')) #>> '{error,code}', 'NOT_FOUND',
          'NT-01 B cannot read A''s inventory history');
select is(api.list_inventory_movements(pg_temp.id('sb'), pg_temp.id('pa')) #>> '{error,code}', 'NOT_FOUND',
          'NT-06 … nor through B''s own store id');
select is(api.list_products(pg_temp.id('sb'), 'SECRET') #> '{data,items}', '[]'::jsonb,
          'NT-01 B''s search never returns A''s products');
select is((select count(*)::int from app.products) + (select count(*)::int from app.product_variants)
          + (select count(*)::int from app.product_images) + (select count(*)::int from app.inventory_movements), 0,
          'NT-01 RLS hides A''s catalog rows from B entirely');
select is(api.get_product(pg_temp.id('sa'), gen_random_uuid()) #>> '{error,code}', 'NOT_FOUND',
          'NT-02 a random id gives the same answer as A''s real id');

-- ---- Writes -------------------------------------------------------------------------------
select is(api.upsert_product(pg_temp.id('sa'), pg_temp.id('pa'), 1, (select v -> 'data' from res where k = 'pa') || '{"name": "Hacked"}',
                             gen_random_uuid()) #>> '{error,code}',
          'NOT_FOUND', 'NT-02 B cannot edit A''s product');
select is(api.upsert_product(pg_temp.id('sb'), pg_temp.id('pa'), 1, '{"name": "Hacked", "base_price": 1, "track_stock": true,
            "status": "active", "option_types": [], "variants": [{"option_values": []}], "images": []}', gen_random_uuid()) #>> '{error,code}',
          'NOT_FOUND', 'NT-06 B cannot edit A''s product through B''s own store');
select is(api.upsert_product(pg_temp.id('sb'), pg_temp.id('pa'), null, '{"name": "Copy", "base_price": 1, "track_stock": true,
            "status": "active", "option_types": [], "variants": [{"option_values": []}], "images": []}', gen_random_uuid()) #>> '{error,code}',
          'NOT_FOUND', 'B cannot take over A''s product id by creating a product with it');
select is(api.upsert_product(pg_temp.id('sa'), gen_random_uuid(), null, '{"name": "Planted", "base_price": 1, "track_stock": true,
            "status": "active", "option_types": [], "variants": [{"option_values": []}], "images": []}', gen_random_uuid()) #>> '{error,code}',
          'NOT_FOUND', 'NT-02 B cannot create a product in A''s store');
select is(api.set_product_status(pg_temp.id('sa'), pg_temp.id('pa'), 1, 'archived') #>> '{error,code}', 'NOT_FOUND',
          'NT-02 B cannot archive A''s product');
select is(api.adjust_stock(pg_temp.id('sa'), pg_temp.id('va'), 'set', 0, 'damaged', null, null, gen_random_uuid()) #>> '{error,code}',
          'NOT_FOUND', 'NT-02 B cannot change A''s stock');
select is(api.adjust_stock(pg_temp.id('sb'), pg_temp.id('va'), 'set', 0, 'damaged', null, null, gen_random_uuid()) #>> '{error,code}',
          'NOT_FOUND', 'NT-06 B cannot change A''s stock through B''s own store id');
select throws_ok($$ update app.product_variants set stock_on_hand = 0 $$, '42501', null, 'NT-10 B cannot write stock directly');
select throws_ok($$ insert into app.inventory_movements (store_id, variant_id, delta, resulting_qty, reason)
                   values ((select v from ids where k = 'sa'), (select v from ids where k = 'va'), -7, 0, 'other') $$,
                 '42501', null, 'NT-10 B cannot write movements directly');

-- ---- Storage (NT-07) ----------------------------------------------------------------------
select is((select count(*)::int from storage.objects where bucket_id = 'store-media'), 0,
          'NT-07 B cannot see A''s image objects (and so cannot get signed URLs for them)');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('store-media', '%s/products/%s/cccccccc-cccc-4ccc-8ccc-cccccccccccc.jpg') $$,
                        pg_temp.id('sa'), pg_temp.id('pa')),
                 '42501', null, 'NT-07 B cannot upload under A''s store prefix');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('store-media', '%s/products/%s/dddddddd-dddd-4ddd-8ddd-dddddddddddd.jpg') $$,
                       pg_temp.id('sb'), pg_temp.id('pb')),
                'B can upload under B''s own prefix');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('store-media', '%s/other/x.png') $$, pg_temp.id('sb')),
                 '42501', null, 'uploads must use the product image path shape');
select is((select count(*)::int from storage.objects), 1, 'B sees only B''s own object');
select is(api.upsert_product(pg_temp.id('sb'), pg_temp.id('pb'), null, jsonb_build_object('name', 'Mine', 'base_price', 1,
            'track_stock', true, 'status', 'active', 'option_types', '[]'::jsonb, 'variants', '[{"option_values": []}]'::jsonb,
            'images', jsonb_build_array(pg_temp.id('sa') || '/products/' || pg_temp.id('pa') || '/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg')),
            gen_random_uuid()) #>> '{error,details,fields,images}',
          'invalid', 'B cannot attach A''s image to B''s product');
select set_config('storage.allow_delete_query', 'true', true);   -- what the Storage API sets for deletes
with d as (delete from storage.objects where name like (select v from ids where k = 'sa') || '/%' returning 1)
select is((select count(*)::int from d), 0, 'NT-07 B cannot delete A''s objects');
with u as (update storage.objects set name = name || '.x' returning 1)
select is((select count(*)::int from u), 0, 'no one can overwrite or rename objects (no update policy)');

-- Seller A: referenced objects are protected; unreferenced ones can be removed.
select pg_temp.act_as(pg_temp.id('a'));
with d as (delete from storage.objects where name like '%aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa.jpg' returning 1)
select is((select count(*)::int from d), 0, 'an image still used by a product cannot be deleted');
with d as (delete from storage.objects where name like '%bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.jpg' returning 1)
select is((select count(*)::int from d), 1, 'an unreferenced upload can be deleted by its store');
select is(api.get_product(pg_temp.id('sa'), pg_temp.id('pa')) #>> '{data,variants,0,stock_on_hand}', '7',
          'A''s stock is unchanged after all of B''s attempts');

-- ---- Anonymous and service callers ----------------------------------------------------------
select pg_temp.act_as_anon();
select throws_ok($$ select api.list_products((select v from ids where k = 'sa')) $$, '42501', null,
                 'NT-04 anonymous callers cannot call catalog functions');
select is((select count(*)::int from storage.objects), 0, 'NT-04 anonymous callers see no objects');

select * from finish();
rollback;
