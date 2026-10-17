-- Catalog rules (Phase 1 US-010..US-013, BR-12/13/17/18; Phase 3 §4.2, contracts §3.3).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(61);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;

insert into ids values ('a', pg_temp.new_user('catalog@example.test')),
  ('p1', gen_random_uuid()), ('p2', gen_random_uuid()), ('p3', gen_random_uuid()),
  ('p4', gen_random_uuid()), ('k1', gen_random_uuid());

select pg_temp.act_as((select v from ids where k = 'a'));
insert into ids select 'store', (api.create_store('Shilan Boutique', '+9647501234567', 'IQD', 'ckb', 'Erbil',
                                                  gen_random_uuid()) #>> '{data,id}')::uuid;

create function pg_temp.sid() returns uuid language sql as $$ select v from ids where k = 'store' $$;
create function pg_temp.id(p text) returns uuid language sql as $$ select v from ids where k = p $$;
create function pg_temp.upsert(p_product uuid, p_version integer, p_body jsonb) returns jsonb language sql as $$
  select api.upsert_product(pg_temp.sid(), p_product, p_version, p_body, gen_random_uuid())
$$;
-- A valid product body; tests override fields with ||.
create function pg_temp.body(p_extra jsonb default '{}') returns jsonb language sql as $$
  select '{"name": "Product", "base_price": 1000, "track_stock": true, "status": "active",
           "option_types": [], "variants": [{"option_values": []}], "images": []}'::jsonb || p_extra
$$;

-- ---- Create without options ------------------------------------------------------------
insert into res select 'p1', api.upsert_product(pg_temp.sid(), pg_temp.id('p1'), null,
  pg_temp.body('{"name": "  Black Abaya ", "description": "Soft crepe", "category": "Clothing",
                 "base_price": 35000, "variants": [{"option_values": [], "initial_stock": 5}]}'),
  pg_temp.id('k1'));
select is((select v ->> 'ok' from res where k = 'p1'), 'true', 'a product is created');
select is((select v #>> '{data,name}' from res where k = 'p1'), 'Black Abaya', 'the name is trimmed');
select is((select jsonb_array_length(v #> '{data,variants}') from res where k = 'p1'), 1,
          'a product without options has exactly one (default) variant');
select is((select v #>> '{data,variants,0,stock_on_hand}' from res where k = 'p1'), '5', 'initial stock is set');
select is((select array_agg(reason || ':' || delta || ':' || resulting_qty) from app.inventory_movements m
            join app.product_variants v on v.id = m.variant_id where v.product_id = pg_temp.id('p1')),
          array['initial_stock:5:5'], 'initial stock is recorded as a movement');
select is(api.upsert_product(pg_temp.sid(), pg_temp.id('p1'), null,
            pg_temp.body('{"name": "  Black Abaya ", "description": "Soft crepe", "category": "Clothing",
                           "base_price": 35000, "variants": [{"option_values": [], "initial_stock": 5}]}'),
            pg_temp.id('k1')),
          (select v from res where k = 'p1'), 'a retry with the same key replays the result');
select is((select count(*)::int from app.inventory_movements), 1, 'the replay wrote no second movement');
select is(api.upsert_product(pg_temp.sid(), pg_temp.id('p1'), null, pg_temp.body(), pg_temp.id('k1')) #>> '{error,code}',
          'IDEMPOTENCY_KEY_REUSED', 'the same key with another request is refused');
select is(pg_temp.upsert(pg_temp.id('p1'), null, pg_temp.body()) #>> '{error,code}', 'CONFLICT_VERSION',
          'creating again with an existing id is a conflict, not a second product');

-- ---- Validation ------------------------------------------------------------------------
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            jsonb_build_object('name', ' ', 'base_price', 0, 'description', repeat('x', 2001),
                               'option_types', '["A","B","C"]'::jsonb, 'status', 'deleted',
                               'images', '["1","2","3","4","5","6"]'::jsonb))) -> 'error' -> 'details' -> 'fields',
          '{"name": "required", "base_price": "out_of_range", "description": "too_long",
            "option_types": "too_many", "status": "invalid", "images": "too_many"}'::jsonb,
          'every invalid product field is reported at once');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body('{"base_price": 12.5}')) #>> '{error,details,fields,base_price}',
          'invalid', 'prices are integers (BR-12)');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body('{"base_price": "1000"}')) #>> '{error,details,fields,base_price}',
          'invalid', 'a price sent as text is refused');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            '{"option_types": ["Size"], "variants": [{"option_values": ["S"]}, {"option_values": ["M", "Red"]}]}'))
            #>> '{error,details,fields,variants.1.option_values}',
          'invalid', 'each active variant has one value per option type');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            '{"option_types": ["Size"], "variants": [{"option_values": ["S"]}, {"option_values": [" s "]}]}'))
            #>> '{error,details,fields,variants.1.option_values}',
          'duplicate', 'duplicate combinations are refused (case-insensitive, trimmed)');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            '{"option_types": ["Size"], "variants": [{"option_values": ["S"], "sku": "X-1"}, {"option_values": ["M"], "sku": "x-1"}]}'))
            #>> '{error,details,fields,variants.1.sku}',
          'duplicate', 'duplicate SKUs in one product are refused');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            '{"variants": [{"option_values": [], "status": "archived"}]}')) #>> '{error,details,fields,variants}',
          'at_least_one_active', 'a product needs at least one active variant');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            '{"variants": [{"option_values": []}, {"option_values": []}]}')) #>> '{error,details,fields,variants}',
          'invalid', 'a product without options has a single active variant (BR-13)');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            '{"variants": [{"option_values": [], "initial_stock": -1}]}')) #>> '{error,details,fields,variants.0.initial_stock}',
          'invalid', 'negative initial stock is refused (BR-14)');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            '{"variants": [{"option_values": [], "price_override": 0}]}')) #>> '{error,details,fields,variants.0.price_override}',
          'invalid', 'a variant price must be a positive integer');
select is(pg_temp.upsert(gen_random_uuid(), null, pg_temp.body(
            jsonb_build_object('variants', (select jsonb_agg(jsonb_build_object('option_values', jsonb_build_array(i::text)))
                                              from generate_series(1, 101) i), 'option_types', '["Size"]'::jsonb)))
            #>> '{error,details,fields,variants}',
          'too_many', 'at most 100 variants');
select is((select count(*)::int from app.products), 1, 'failed attempts created nothing');

-- ---- Options and variants ------------------------------------------------------------
insert into res select 'p2', pg_temp.upsert(pg_temp.id('p2'), null, pg_temp.body(
  '{"name": "Linen Shirt", "category": "clothing ", "base_price": 25000, "option_types": ["Size"],
    "variants": [{"option_values": ["S"], "sku": "SH-S", "initial_stock": 2},
                 {"option_values": ["M"], "sku": "SH-M", "price_override": 27000}]}'));
select is((select v #>> '{data,category}' from res where k = 'p2'), 'Clothing',
          'a category reuses the store''s existing spelling');
select is((select array_agg(x ->> 'label' order by x ->> 'label') from res, jsonb_array_elements(v #> '{data,variants}') x where k = 'p2'),
          array['M', 'S'], 'variants are labelled with their option values');
select is((select array_agg((x ->> 'price')::int order by (x ->> 'price')::int) from res, jsonb_array_elements(v #> '{data,variants}') x where k = 'p2'),
          array[25000, 27000], 'variant prices default to the product price unless overridden');
select is(pg_temp.upsert(pg_temp.id('p3'), null, pg_temp.body('{"variants": [{"option_values": [], "sku": "sh-s"}]}'))
            #>> '{error,details,fields,variants.0.sku}',
          'duplicate', 'a SKU is unique in the store, case-insensitively');

insert into ids select 'v_s', (x ->> 'id')::uuid from res, jsonb_array_elements(v #> '{data,variants}') x where k = 'p2' and x ->> 'label' = 'S';
insert into ids select 'v_m', (x ->> 'id')::uuid from res, jsonb_array_elements(v #> '{data,variants}') x where k = 'p2' and x ->> 'label' = 'M';

-- ---- Editing ------------------------------------------------------------------------
select is(pg_temp.upsert(pg_temp.id('p2'), 99, pg_temp.body()) #>> '{error,code}', 'CONFLICT_VERSION',
          'a stale version is a conflict');
insert into res select 'p2e', pg_temp.upsert(pg_temp.id('p2'), 1, pg_temp.body(jsonb_build_object(
  'name', 'Linen Shirt', 'base_price', 26000, 'option_types', '["Size"]'::jsonb,
  'variants', jsonb_build_array(
    jsonb_build_object('id', pg_temp.id('v_s'), 'option_values', '["S"]'::jsonb, 'sku', 'SH-S', 'initial_stock', 50),
    jsonb_build_object('id', pg_temp.id('v_m'), 'option_values', '["M"]'::jsonb, 'sku', 'SH-M')))));
select is((select v #>> '{data,version}' from res where k = 'p2e'), '2', 'an edit increments the version');
select is((select stock_on_hand from app.product_variants where id = pg_temp.id('v_s')), 2,
          'editing never changes the stock of an existing variant');
select is((select (after ->> 'base_price')::int from app.audit_events where action = 'product.update' and entity_id = pg_temp.id('p2')),
          26000, 'price changes are audited with the new value');
select is((select (before ->> 'base_price')::int from app.audit_events where action = 'product.update' and entity_id = pg_temp.id('p2')),
          25000, '… and the previous value');

select is(pg_temp.upsert(pg_temp.id('p2'), 2, pg_temp.body(jsonb_build_object(
            'option_types', '["Size"]'::jsonb,
            'variants', jsonb_build_array(jsonb_build_object('id', pg_temp.id('v_m'), 'option_values', '["M"]'::jsonb)))))
            #>> '{error,code}',
          'VARIANT_IN_USE', 'a variant with stock or history cannot be removed');
insert into res select 'p2a', pg_temp.upsert(pg_temp.id('p2'), 2, pg_temp.body(jsonb_build_object(
  'name', 'Linen Shirt', 'base_price', 26000, 'option_types', '["Size"]'::jsonb,
  'variants', jsonb_build_array(
    jsonb_build_object('id', pg_temp.id('v_s'), 'option_values', '["S"]'::jsonb, 'status', 'archived'),
    jsonb_build_object('id', pg_temp.id('v_m'), 'option_values', '["M"]'::jsonb)))));
select is((select status || ':' || stock_on_hand from app.product_variants where id = pg_temp.id('v_s')),
          'archived:2', 'it can be archived instead; its stock and history stay');
select is((select sku from app.product_variants where id = pg_temp.id('v_s')), null,
          'a SKU left out of an edit is cleared');
select is(pg_temp.upsert(pg_temp.id('p2'), 3, pg_temp.body(jsonb_build_object(
            'name', 'Linen Shirt', 'base_price', 26000, 'option_types', '["Size"]'::jsonb,
            'variants', jsonb_build_array(
              jsonb_build_object('option_values', '["s"]'::jsonb),
              jsonb_build_object('id', pg_temp.id('v_m'), 'option_values', '["M"]'::jsonb)))))
            #>> '{data,variants,0,id}',
          pg_temp.id('v_s')::text, 're-adding an archived combination restores the same variant');
select is(pg_temp.upsert(pg_temp.id('p2'), 4, pg_temp.body(jsonb_build_object(
            'name', 'Linen Shirt', 'base_price', 26000, 'option_types', '["Size"]'::jsonb,
            'variants', jsonb_build_array(jsonb_build_object('id', pg_temp.id('v_s'), 'option_values', '["S"]'::jsonb)))))
            ->> 'ok',
          'true', 'a variant that never held stock is deleted when left out');
select ok(not exists (select 1 from app.product_variants where id = pg_temp.id('v_m')), '… and it is gone');

-- ---- Status (archive instead of delete, BR-17) ------------------------------------------
select is(api.set_product_status(pg_temp.sid(), pg_temp.id('p2'), 1, 'archived') #>> '{error,code}', 'CONFLICT_VERSION',
          'changing status checks the version');
select is(api.set_product_status(pg_temp.sid(), pg_temp.id('p2'), 5, 'archived') #>> '{data,status}', 'archived',
          'a product is archived');
select is(api.set_product_status(pg_temp.sid(), pg_temp.id('p2'), 1, 'archived') #>> '{data,status}', 'archived',
          'archiving again is a harmless no-op (safe retry)');
select is(api.set_product_status(pg_temp.sid(), pg_temp.id('p2'), 6, 'deleted') #>> '{error,details,fields,status}', 'invalid',
          'there is no delete status');
select is(pg_temp.upsert(pg_temp.id('p2'), 6, pg_temp.body(jsonb_build_object(
            'name', 'Linen Shirt', 'base_price', 26000, 'option_types', '["Size"]'::jsonb,
            'variants', jsonb_build_array(jsonb_build_object('id', pg_temp.id('v_s'), 'option_values', '["S"]'::jsonb)))))
            #>> '{data,status}',
          'archived', 'editing an archived product keeps it archived');

-- ---- Images -----------------------------------------------------------------------------
select pg_temp.act_as_admin();
insert into storage.objects (bucket_id, name) values
  ('store-media', pg_temp.sid() || '/products/' || pg_temp.id('p1') || '/' || '11111111-1111-4111-8111-111111111111.jpg'),
  ('store-media', pg_temp.sid() || '/products/' || pg_temp.id('p1') || '/' || '22222222-2222-4222-8222-222222222222.jpg'),
  ('store-media', pg_temp.sid() || '/products/' || pg_temp.id('p2') || '/' || '33333333-3333-4333-8333-333333333333.jpg');
select pg_temp.act_as(pg_temp.id('a'));
create function pg_temp.img(p_product text, p_file text) returns text language sql as $$
  select pg_temp.sid() || '/products/' || pg_temp.id(p_product) || '/' || p_file || '.jpg'
$$;

select is(pg_temp.upsert(pg_temp.id('p1'), 1, pg_temp.body(jsonb_build_object(
            'images', jsonb_build_array(pg_temp.img('p1', '99999999-9999-4999-8999-999999999999'))))) #>> '{error,details,fields,images}',
          'invalid', 'an image that was never uploaded cannot be attached');
select is(pg_temp.upsert(pg_temp.id('p1'), 1, pg_temp.body(jsonb_build_object(
            'images', jsonb_build_array(pg_temp.img('p2', '33333333-3333-4333-8333-333333333333'))))) #>> '{error,details,fields,images}',
          'invalid', 'an image uploaded for another product cannot be attached');
insert into res select 'img', pg_temp.upsert(pg_temp.id('p1'), 1, pg_temp.body(jsonb_build_object(
  'name', 'Black Abaya', 'base_price', 35000, 'category', 'Clothing',
  'images', jsonb_build_array(pg_temp.img('p1', '22222222-2222-4222-8222-222222222222'),
                              pg_temp.img('p1', '11111111-1111-4111-8111-111111111111')))));
select is((select v #>> '{data,images,0,path}' from res where k = 'img'), pg_temp.img('p1', '22222222-2222-4222-8222-222222222222'),
          'images keep the order sent; the first is the main image');
insert into res select 'img2', pg_temp.upsert(pg_temp.id('p1'), 2, pg_temp.body(jsonb_build_object(
  'name', 'Black Abaya', 'base_price', 35000, 'category', 'Clothing',
  'images', jsonb_build_array(pg_temp.img('p1', '11111111-1111-4111-8111-111111111111')))));
select is((select v #> '{data,removed_image_paths}' from res where k = 'img2'),
          jsonb_build_array(pg_temp.img('p1', '22222222-2222-4222-8222-222222222222')),
          'removing an image returns its path so the app can delete the object');

-- ---- Untracked product (BR-16) and a second tracked one for filters -----------------------
insert into res select 'p3', pg_temp.upsert(pg_temp.id('p3'), null, pg_temp.body(
  '{"name": "Oud decant كراس", "category": "Perfumes", "base_price": 15000, "track_stock": false,
    "variants": [{"option_values": [], "available": false, "initial_stock": 9}]}'));
select is((select v #>> '{data,variants,0,stock_on_hand}' from res where k = 'p3'), '0',
          'an untracked product records no stock, even if some is sent');
insert into res select 'p4', pg_temp.upsert(pg_temp.id('p4'), null, pg_temp.body(
  '{"name": "Leather Bag", "category": "Shoes and bags", "base_price": 50000, "status": "inactive",
    "variants": [{"option_values": [], "sku": "BAG-01", "initial_stock": 2}]}'));

-- ---- Search, filters, sort, paging ----------------------------------------------------
create function pg_temp.names(p_result jsonb) returns text[] language sql as $$
  select coalesce(array_agg(x ->> 'name' order by o), '{}') from jsonb_array_elements(p_result #> '{data,items}') with ordinality e(x, o)
$$;
select is(pg_temp.names(api.list_products(pg_temp.sid(), 'ABAYA')), array['Black Abaya'], 'search by name is case-insensitive');
select is(pg_temp.names(api.list_products(pg_temp.sid(), 'bag-0')), array['Leather Bag'], 'search finds SKUs');
select is(pg_temp.names(api.list_products(pg_temp.sid(), 'کراس')), array['Oud decant كراس'],
          'Arabic and Kurdish letter forms match (ك = ک)');
select is(pg_temp.names(api.list_products(pg_temp.sid(), '%')), '{}'::text[], 'LIKE wildcards in a query are literal');
select is(pg_temp.names(api.list_products(pg_temp.sid(), null, 'all', null, 'name')),
          array['Black Abaya', 'Leather Bag', 'Oud decant كراس'], 'All excludes archived products; sorted by name');
select is(pg_temp.names(api.list_products(pg_temp.sid(), null, 'archived')), array['Linen Shirt'], 'Archived shows archived products');
select is(pg_temp.names(api.list_products(pg_temp.sid(), null, 'low', null, 'name')), array['Leather Bag'],
          'Low stock: at or below the store default (3)');
select is(pg_temp.names(api.list_products(pg_temp.sid(), null, 'out')), array['Oud decant كراس'],
          'Out of stock includes unavailable untracked products');
select is(pg_temp.names(api.list_products(pg_temp.sid(), null, 'all', 'CLOTHING')), array['Black Abaya'],
          'category filter (case-insensitive)');
select is((api.list_products(pg_temp.sid(), null, 'all', null, 'name', 1, 0) #> '{data}') - 'items'::text,
          '{"total": 3, "has_more": true}'::jsonb, 'pages report the total and whether more follow');
select is(api.list_products(pg_temp.sid(), null, 'bogus') #>> '{error,details,fields,filter}', 'invalid', 'unknown filters are refused');
select is((api.catalog_summary(pg_temp.sid()) -> 'data') - 'categories'::text,
          '{"total": 4, "all": 3, "low": 1, "out": 1, "inactive": 1, "archived": 1, "low_stock_default": 3}'::jsonb,
          'summary counts match the filters');

-- ---- Store settings that depend on the catalog ------------------------------------------
select is(api.update_store(pg_temp.sid(), 1, '{"currency": "USD"}', gen_random_uuid()) #>> '{error,details,reason}',
          'products_exist', 'the currency cannot change once products exist (prices are never converted)');
select is(api.update_store(pg_temp.sid(), 1, '{"low_stock_default": 1}', gen_random_uuid()) #>> '{data,low_stock_default}',
          '1', 'the low-stock default is a store setting');
select is(pg_temp.names(api.list_products(pg_temp.sid(), null, 'low')), '{}'::text[],
          'changing the default changes which products are low (BR-18)');

select * from finish();
rollback;
