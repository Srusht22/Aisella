-- Aisellia — Phase 6: product catalog, variants, images and inventory.
--
-- Model (Phase 3 backend-and-data-model.md §4.2, ADR-004, Phase 1 BR-12..BR-18, US-010..US-017):
--   * products → product_variants (≥ 1; a product without options has one default variant whose
--     option_values is '{}') → inventory_movements (append-only ledger).
--   * Stock lives on variants: stock_on_hand is a balance maintained in the same transaction as
--     the ledger row, CHECK ≥ 0 as a backstop; Σ delta per variant = stock_on_hand (reconciled).
--   * Prices are integers in the store currency (BR-12, D-08): IQD has no minor unit in use and USD
--     is whole dollars in P0. No conversion; the store currency cannot change once products exist.
--   * Images: private bucket `store-media`, path `{store_id}/products/{product_id}/{uuid}.jpg`,
--     referenced by product_images (≤ 5 per product). Storage policies check the path's store.
--   * Same rules as Phase 5: tables in `app` with SELECT-only RLS; every mutation is an `api`
--     SECURITY DEFINER function that authorizes, validates, audits and returns the envelope;
--     non-members get NOT_FOUND; retryable mutations take an idempotency key.

create extension if not exists pg_trgm with schema extensions;

-- ---------------------------------------------------------------------------------------------
-- Store default low-stock threshold (BR-18). Phase 6 decision P6-D2: default 3, configurable.
-- ---------------------------------------------------------------------------------------------
alter table app.stores
  add column low_stock_default integer not null default 3 check (low_stock_default between 0 and 9999);

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------
create table app.products (
  id           uuid primary key,
  store_id     uuid not null references app.stores (id),
  name         text not null check (char_length(name) between 1 and 120 and name = btrim(name)),
  description  text check (description is null or (char_length(description) between 1 and 2000)),
  category     text check (category is null or (char_length(category) between 1 and 60 and category = btrim(category))),
  base_price   integer not null check (base_price between 1 and 1000000000),
  track_stock  boolean not null default true,
  option_types text[] not null default '{}' check (cardinality(option_types) <= 2),
  status       text not null default 'active' check (status in ('active', 'inactive', 'archived')),
  search_text  text not null default '',
  version      integer not null default 1 check (version >= 1),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (store_id, id)
);
create index products_store_status on app.products (store_id, status, updated_at desc);
create index products_store_category on app.products (store_id, lower(category));
create index products_search on app.products using gin (search_text extensions.gin_trgm_ops);

create table app.product_variants (
  id                  uuid primary key default gen_random_uuid(),
  store_id            uuid not null,
  product_id          uuid not null,
  option_values       text[] not null default '{}' check (cardinality(option_values) <= 2),
  label               text not null default '',
  sku                 text check (sku is null or (char_length(sku) between 1 and 64 and sku = btrim(sku))),
  price_override      integer check (price_override is null or price_override between 1 and 1000000000),
  stock_on_hand       integer not null default 0 check (stock_on_hand between 0 and 1000000),
  available           boolean not null default true,
  low_stock_threshold integer check (low_stock_threshold is null or low_stock_threshold between 0 and 9999),
  status              text not null default 'active' check (status in ('active', 'archived')),
  position            integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (store_id, id),
  foreign key (store_id, product_id) references app.products (store_id, id) on delete cascade,
  constraint product_variants_unique_combination unique (product_id, option_values) deferrable initially deferred
);
create index product_variants_product on app.product_variants (product_id, position);
-- SKU unique per store, case-insensitively (Phase 1 US-010).
create unique index product_variants_store_sku on app.product_variants (store_id, lower(sku)) where sku is not null;

create table app.product_images (
  id           uuid primary key default gen_random_uuid(),
  store_id     uuid not null,
  product_id   uuid not null,
  storage_path text not null unique,
  position     integer not null check (position between 0 and 4),
  created_at   timestamptz not null default now(),
  foreign key (store_id, product_id) references app.products (store_id, id) on delete cascade,
  unique (product_id, position)
);

create table app.inventory_movements (
  id            bigint generated always as identity primary key,
  store_id      uuid not null,
  variant_id    uuid not null,
  delta         integer not null check (delta <> 0),
  resulting_qty integer not null check (resulting_qty >= 0),
  -- Manual reasons (Phase 2 PR-05) plus the order reasons Phase 7 will write (Phase 3 §4.2).
  reason        text not null check (reason in ('initial_stock', 'received', 'sold_in_shop', 'damaged',
                                                'count_correction', 'other', 'order_approved',
                                                'order_edited', 'order_cancelled', 'order_returned_restock')),
  note          text check (note is null or char_length(note) between 1 and 200),
  actor_user_id uuid,
  created_at    timestamptz not null default now(),
  foreign key (store_id, variant_id) references app.product_variants (store_id, id)
);
create index inventory_movements_variant on app.inventory_movements (variant_id, id desc);
create index inventory_movements_store on app.inventory_movements (store_id, id desc);

-- The ledger is append-only (BR-64). Only the account purge job may delete, and it says so
-- explicitly for its own transaction.
create function app.protect_ledger()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('aisellia.purge', true), '') = 'on' then
    return old;
  end if;
  raise exception 'inventory_movements is append-only (%)', tg_op using errcode = 'AS002';
end;
$$;
create trigger inventory_movements_append_only
  before update or delete on app.inventory_movements
  for each row execute function app.protect_ledger();

-- ---------------------------------------------------------------------------------------------
-- RLS (defence in depth; the app reads through the api functions below).
-- ---------------------------------------------------------------------------------------------
alter table app.products enable row level security;
alter table app.product_variants enable row level security;
alter table app.product_images enable row level security;
alter table app.inventory_movements enable row level security;

create policy products_select_member on app.products
  for select to authenticated using (app.is_member(store_id));
create policy product_variants_select_member on app.product_variants
  for select to authenticated using (app.is_member(store_id));
create policy product_images_select_member on app.product_images
  for select to authenticated using (app.is_member(store_id));
create policy inventory_movements_select_member on app.inventory_movements
  for select to authenticated using (app.is_member(store_id));

revoke all on app.products, app.product_variants, app.product_images, app.inventory_movements
  from public, anon, authenticated;
grant select on app.products, app.product_variants, app.product_images, app.inventory_movements
  to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------------------------

-- Search normalisation shared by stored text and queries: Arabic/Persian letter variants to the
-- Sorani forms, Eastern digits to Western, no tatweel or ZWNJ, lower case, single spaces.
create function app.search_normalize(p_text text)
returns text language sql immutable parallel safe
as $$
  select btrim(regexp_replace(lower(translate(coalesce(p_text, ''),
    'يىك٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹ـ‌',
    'ییک01234567890123456789')), '\s+', ' ', 'g'));
$$;

-- Effective permission check usable by storage policies (Phase 3 authorization §3).
create function app.has_permission(p_store_id uuid, p_permission text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_store_id is not null and app.is_member(p_store_id) and exists (
    select 1 from app.store_members m
     where m.store_id = p_store_id and m.user_id = (select auth.uid())
       and (m.role = 'owner' or coalesce((m.permissions ->> p_permission)::boolean, false))
  );
$$;

-- Store id from a media object path `{store_id}/products/{product_id}/{uuid}.jpg`, or null.
create function app.media_store_id(p_name text)
returns uuid language sql immutable
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/products/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
    then split_part(p_name, '/', 1)::uuid
  end;
$$;

-- Whether a media object is still referenced by a product (then it must not be deleted).
create function app.media_referenced(p_name text)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from app.product_images where storage_path = p_name);
$$;

create function app.variant_label(p_values text[])
returns text language sql immutable
as $$ select array_to_string(p_values, ' · ') $$;

-- Public shape of a product with its variants and images (the contract for every reader).
create function app.product_json(p_product_id uuid)
returns jsonb
language sql stable
as $$
  select jsonb_build_object(
    'id', p.id,
    'store_id', p.store_id,
    'name', p.name,
    'description', p.description,
    'category', p.category,
    'base_price', p.base_price,
    'track_stock', p.track_stock,
    'option_types', to_jsonb(p.option_types),
    'status', p.status,
    'version', p.version,
    'created_at', p.created_at,
    'updated_at', p.updated_at,
    'low_stock_default', s.low_stock_default,
    'variants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', v.id,
        'option_values', to_jsonb(v.option_values),
        'label', v.label,
        'sku', v.sku,
        'price_override', v.price_override,
        'price', coalesce(v.price_override, p.base_price),
        'stock_on_hand', v.stock_on_hand,
        'available', v.available,
        'low_stock_threshold', v.low_stock_threshold,
        'status', v.status,
        'has_history', exists (select 1 from app.inventory_movements m where m.variant_id = v.id)
      ) order by v.position, v.created_at, v.id)
      from app.product_variants v where v.product_id = p.id), '[]'::jsonb),
    'images', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'path', i.storage_path, 'position', i.position)
                       order by i.position)
      from app.product_images i where i.product_id = p.id), '[]'::jsonb)
  )
  from app.products p join app.stores s on s.id = p.store_id
  where p.id = p_product_id;
$$;

-- Read access to a store's catalog: members only, NOT_FOUND otherwise (no existence leak).
create function app.require_member(p_store_id uuid)
returns void
language plpgsql stable
as $$
begin
  if p_store_id is null or not app.is_member(p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
end;
$$;

-- Validation of the product payload of upsert_product. Returns {field: rule}; variant fields are
-- reported as `variants.<index>.<field>` (0-based, in the order sent).
create function app.product_field_errors(p_product jsonb, p_existing_ids uuid[])
returns jsonb
language plpgsql stable
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_text text;
  v_types jsonb := coalesce(p_product -> 'option_types', '[]'::jsonb);
  v_variants jsonb := coalesce(p_product -> 'variants', '[]'::jsonb);
  v_images jsonb := coalesce(p_product -> 'images', '[]'::jsonb);
  v_variant jsonb;
  v_values jsonb;
  v_i integer := 0;
  v_type_count integer;
  v_active integer := 0;
  v_seen_combos text[] := '{}';
  v_seen_skus text[] := '{}';
  v_key text;
  v_num jsonb;
begin
  v_text := p_product ->> 'name';
  if v_text is null or char_length(btrim(v_text)) = 0 then
    v_errors := v_errors || '{"name": "required"}';
  elsif char_length(btrim(v_text)) > 120 then
    v_errors := v_errors || '{"name": "too_long"}';
  end if;
  if char_length(coalesce(btrim(p_product ->> 'description'), '')) > 2000 then
    v_errors := v_errors || '{"description": "too_long"}';
  end if;
  if char_length(coalesce(btrim(p_product ->> 'category'), '')) > 60 then
    v_errors := v_errors || '{"category": "too_long"}';
  end if;
  v_num := p_product -> 'base_price';
  if v_num is null or jsonb_typeof(v_num) = 'null' then
    v_errors := v_errors || '{"base_price": "required"}';
  elsif jsonb_typeof(v_num) <> 'number' or (v_num::text)::numeric <> trunc((v_num::text)::numeric) then
    v_errors := v_errors || '{"base_price": "invalid"}';
  elsif (v_num::text)::numeric not between 1 and 1000000000 then
    v_errors := v_errors || '{"base_price": "out_of_range"}';
  end if;
  if jsonb_typeof(coalesce(p_product -> 'track_stock', 'null'::jsonb)) <> 'boolean' then
    v_errors := v_errors || '{"track_stock": "invalid"}';
  end if;
  if coalesce(p_product ->> 'status', '') not in ('active', 'inactive') then
    v_errors := v_errors || '{"status": "invalid"}';
  end if;

  -- Option types: up to 2 distinct names of 1–30 characters.
  if jsonb_typeof(v_types) <> 'array' or jsonb_array_length(v_types) > 2 then
    v_errors := v_errors || '{"option_types": "too_many"}';
    v_type_count := 0;
  else
    v_type_count := jsonb_array_length(v_types);
    if exists (select 1 from jsonb_array_elements(v_types) t
                where jsonb_typeof(t) <> 'string' or char_length(btrim(t #>> '{}')) not between 1 and 30) then
      v_errors := v_errors || '{"option_types": "invalid"}';
    elsif (select count(distinct lower(btrim(t #>> '{}'))) from jsonb_array_elements(v_types) t) <> v_type_count then
      v_errors := v_errors || '{"option_types": "duplicate"}';
    end if;
  end if;

  -- Variants: 1–100; active ones match the option types; unique combinations and SKUs.
  if jsonb_typeof(v_variants) <> 'array' or jsonb_array_length(v_variants) = 0 then
    return v_errors || '{"variants": "required"}';
  end if;
  if jsonb_array_length(v_variants) > 100 then
    return v_errors || '{"variants": "too_many"}';
  end if;
  for v_variant in select * from jsonb_array_elements(v_variants) loop
    v_key := 'variants.' || v_i || '.';
    if v_variant ? 'id' and jsonb_typeof(v_variant -> 'id') = 'string'
       and not ((v_variant ->> 'id')::uuid = any (p_existing_ids)) then
      v_errors := v_errors || jsonb_build_object(v_key || 'id', 'unknown');
    end if;
    v_values := coalesce(v_variant -> 'option_values', '[]'::jsonb);
    if jsonb_typeof(v_values) <> 'array'
       or exists (select 1 from jsonb_array_elements(v_values) x
                   where jsonb_typeof(x) <> 'string' or char_length(btrim(x #>> '{}')) not between 1 and 30) then
      v_errors := v_errors || jsonb_build_object(v_key || 'option_values', 'invalid');
    elsif coalesce(v_variant ->> 'status', 'active') = 'active' then
      v_active := v_active + 1;
      if jsonb_array_length(v_values) <> v_type_count then
        v_errors := v_errors || jsonb_build_object(v_key || 'option_values', 'invalid');
      end if;
    end if;
    if coalesce(v_variant ->> 'status', 'active') not in ('active', 'archived') then
      v_errors := v_errors || jsonb_build_object(v_key || 'status', 'invalid');
    end if;
    if jsonb_typeof(v_values) = 'array' then
      v_text := lower((select string_agg(btrim(x #>> '{}'), chr(31)) from jsonb_array_elements(v_values) x));
      if coalesce(v_text, '') = any (v_seen_combos) then
        v_errors := v_errors || jsonb_build_object(v_key || 'option_values', 'duplicate');
      end if;
      v_seen_combos := v_seen_combos || coalesce(v_text, '');
    end if;
    v_text := nullif(btrim(coalesce(v_variant ->> 'sku', '')), '');
    if v_text is not null then
      if char_length(v_text) > 64 then
        v_errors := v_errors || jsonb_build_object(v_key || 'sku', 'too_long');
      elsif lower(v_text) = any (v_seen_skus) then
        v_errors := v_errors || jsonb_build_object(v_key || 'sku', 'duplicate');
      end if;
      v_seen_skus := v_seen_skus || lower(v_text);
    end if;
    v_num := v_variant -> 'price_override';
    if v_num is not null and jsonb_typeof(v_num) <> 'null' and (
         jsonb_typeof(v_num) <> 'number' or (v_num::text)::numeric <> trunc((v_num::text)::numeric)
         or (v_num::text)::numeric not between 1 and 1000000000) then
      v_errors := v_errors || jsonb_build_object(v_key || 'price_override', 'invalid');
    end if;
    v_num := v_variant -> 'initial_stock';
    if v_num is not null and jsonb_typeof(v_num) <> 'null' and (
         jsonb_typeof(v_num) <> 'number' or (v_num::text)::numeric <> trunc((v_num::text)::numeric)
         or (v_num::text)::numeric not between 0 and 1000000) then
      v_errors := v_errors || jsonb_build_object(v_key || 'initial_stock', 'invalid');
    end if;
    v_num := v_variant -> 'low_stock_threshold';
    if v_num is not null and jsonb_typeof(v_num) <> 'null' and (
         jsonb_typeof(v_num) <> 'number' or (v_num::text)::numeric <> trunc((v_num::text)::numeric)
         or (v_num::text)::numeric not between 0 and 9999) then
      v_errors := v_errors || jsonb_build_object(v_key || 'low_stock_threshold', 'invalid');
    end if;
    if v_variant ? 'available' and jsonb_typeof(v_variant -> 'available') <> 'boolean' then
      v_errors := v_errors || jsonb_build_object(v_key || 'available', 'invalid');
    end if;
    v_i := v_i + 1;
  end loop;
  if v_active = 0 then
    v_errors := v_errors || '{"variants": "at_least_one_active"}';
  elsif v_type_count = 0 and v_active > 1 then
    v_errors := v_errors || '{"variants": "invalid"}';
  end if;

  -- Images: up to 5 distinct paths (ownership and existence are checked by the caller).
  if jsonb_typeof(v_images) <> 'array' then
    v_errors := v_errors || '{"images": "invalid"}';
  elsif jsonb_array_length(v_images) > 5 then
    v_errors := v_errors || '{"images": "too_many"}';
  elsif (select count(distinct x #>> '{}') from jsonb_array_elements(v_images) x) <> jsonb_array_length(v_images) then
    v_errors := v_errors || '{"images": "duplicate"}';
  end if;
  return v_errors;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.upsert_product: create (p_expected_version null) or edit a product with its variants and
-- image list in one transaction (Phase 3 contracts §3.3, Phase 1 US-010/011/012).
--   * The client chooses the new product's id so images can be uploaded before the first save.
--   * Stock of existing variants is never changed here (only adjust_stock and orders move stock);
--     new tracked variants may carry initial_stock, written as an `initial_stock` movement.
--   * A variant left out of the list is deleted only if it never had stock or movements;
--     otherwise VARIANT_IN_USE (the seller archives it instead).
--   * Returns the product plus `removed_image_paths`, the objects the client should now delete.
-- ---------------------------------------------------------------------------------------------
create function api.upsert_product(
  p_store_id uuid,
  p_product_id uuid,
  p_expected_version integer,
  p_product jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_existing app.products;
  v_product app.products;
  v_is_new boolean := p_expected_version is null;
  v_existing_ids uuid[] := '{}';
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_payload jsonb;
  v_name text;
  v_description text;
  v_category text;
  v_types text[];
  v_variant jsonb;
  v_values text[];
  v_target app.product_variants;
  v_kept uuid[] := '{}';
  v_in_use uuid[];
  v_i integer := 0;
  v_sku text;
  v_initial integer;
  v_old_images text[];
  v_new_images text[];
  v_path text;
  v_before jsonb;
  v_after jsonb;
  v_price_changed boolean := false;
  v_code text;
  v_detail text;
  v_state text;
  v_constraint text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'catalog.edit');
  if p_product_id is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"product_id": "required"}}');
  end if;
  if p_product is null or jsonb_typeof(p_product) <> 'object' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"product": "required"}}');
  end if;

  if not v_is_new then
    select * into v_existing from app.products where id = p_product_id and store_id = p_store_id;
    if not found then
      perform app.fail('NOT_FOUND');
    end if;
    select coalesce(array_agg(id), '{}') into v_existing_ids
      from app.product_variants where product_id = p_product_id;
  end if;

  v_errors := app.product_field_errors(p_product, v_existing_ids);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  -- Normalised values.
  v_name := btrim(p_product ->> 'name');
  v_description := nullif(btrim(coalesce(p_product ->> 'description', '')), '');
  v_category := nullif(btrim(coalesce(p_product ->> 'category', '')), '');
  if v_category is not null then
    -- Reuse the spelling already used in this store (one category, not "Shoes" and "shoes").
    v_category := coalesce((
      select category from app.products
       where store_id = p_store_id and lower(category) = lower(v_category) and id <> p_product_id
       order by created_at limit 1), v_category);
  end if;
  select coalesce(array_agg(btrim(t #>> '{}') order by o), '{}') into v_types
    from jsonb_array_elements(coalesce(p_product -> 'option_types', '[]'::jsonb)) with ordinality as x(t, o);

  v_payload := jsonb_build_object('store_id', p_store_id, 'product_id', p_product_id,
                                  'version', p_expected_version, 'product', p_product);
  v_hash := app.request_hash(v_payload);
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'upsert_product', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  -- Images: every path must be this store's and this product's, and the object must exist.
  select coalesce(array_agg(x #>> '{}' order by o), '{}') into v_new_images
    from jsonb_array_elements(coalesce(p_product -> 'images', '[]'::jsonb)) with ordinality as i(x, o);
  foreach v_path in array v_new_images loop
    if app.media_store_id(v_path) is distinct from p_store_id
       or split_part(v_path, '/', 3) <> p_product_id::text
       or not exists (select 1 from storage.objects o where o.bucket_id = 'store-media' and o.name = v_path) then
      perform app.fail('VALIDATION_FAILED', '{"fields": {"images": "invalid"}}');
    end if;
  end loop;

  if v_is_new then
    if exists (select 1 from app.products where id = p_product_id) then
      if exists (select 1 from app.products where id = p_product_id and store_id = p_store_id) then
        perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version',
          (select version from app.products where id = p_product_id)));
      end if;
      perform app.fail('NOT_FOUND');
    end if;
    insert into app.products (id, store_id, name, description, category, base_price, track_stock,
                              option_types, status)
    values (p_product_id, p_store_id, v_name, v_description, v_category,
            (p_product ->> 'base_price')::integer, (p_product ->> 'track_stock')::boolean, v_types,
            p_product ->> 'status')
    returning * into v_product;
  else
    select * into v_existing from app.products where id = p_product_id for update;
    if v_existing.version <> p_expected_version then
      perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_existing.version));
    end if;
    v_price_changed := v_existing.base_price <> (p_product ->> 'base_price')::integer;
    update app.products set
      name = v_name,
      description = v_description,
      category = v_category,
      base_price = (p_product ->> 'base_price')::integer,
      track_stock = (p_product ->> 'track_stock')::boolean,
      option_types = v_types,
      -- An archived product stays archived until set_product_status restores it.
      status = case when status = 'archived' then 'archived' else p_product ->> 'status' end,
      version = version + 1,
      updated_at = now()
    where id = p_product_id
    returning * into v_product;
    -- Variants are locked in id order (deadlock avoidance with adjust_stock and later approvals).
    perform 1 from app.product_variants where product_id = p_product_id order by id for update;
  end if;

  -- Variants.
  for v_variant in select * from jsonb_array_elements(p_product -> 'variants') loop
    select coalesce(array_agg(btrim(x #>> '{}') order by o), '{}') into v_values
      from jsonb_array_elements(coalesce(v_variant -> 'option_values', '[]'::jsonb)) with ordinality as y(x, o);
    v_sku := nullif(btrim(coalesce(v_variant ->> 'sku', '')), '');
    v_target := null;
    if v_variant ? 'id' and jsonb_typeof(v_variant -> 'id') = 'string' then
      select * into v_target from app.product_variants where id = (v_variant ->> 'id')::uuid;
    elsif not v_is_new then
      -- A combination that existed before (for example archived) is reused, not duplicated.
      select * into v_target from app.product_variants
       where product_id = p_product_id and lower(option_values::text) = lower(v_values::text)
         and not (id = any (v_kept));
    end if;

    -- SKU unique per store: another product's variant may not use it. (Duplicates within this
    -- request were rejected by validation; this product's own old SKUs are released below.)
    if v_sku is not null and exists (
         select 1 from app.product_variants
          where store_id = p_store_id and lower(sku) = lower(v_sku) and product_id <> p_product_id) then
      perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields',
        jsonb_build_object('variants.' || v_i || '.sku', 'duplicate')));
    end if;

    if v_target.id is not null then
      if v_target.price_override is distinct from (v_variant ->> 'price_override')::integer then
        v_price_changed := true;
      end if;
      update app.product_variants set
        option_values = v_values,
        label = app.variant_label(v_values),
        sku = null,  -- set below, after every variant released its old SKU
        price_override = (v_variant ->> 'price_override')::integer,
        available = coalesce((v_variant ->> 'available')::boolean, true),
        low_stock_threshold = (v_variant ->> 'low_stock_threshold')::integer,
        status = coalesce(v_variant ->> 'status', 'active'),
        position = v_i,
        updated_at = now()
      where id = v_target.id;
      v_kept := v_kept || v_target.id;
    else
      insert into app.product_variants (store_id, product_id, option_values, label, sku, price_override,
                                        available, low_stock_threshold, status, position)
      values (p_store_id, p_product_id, v_values, app.variant_label(v_values), null,
              (v_variant ->> 'price_override')::integer,
              coalesce((v_variant ->> 'available')::boolean, true),
              (v_variant ->> 'low_stock_threshold')::integer,
              coalesce(v_variant ->> 'status', 'active'), v_i)
      returning * into v_target;
      v_kept := v_kept || v_target.id;
      v_initial := coalesce((v_variant ->> 'initial_stock')::integer, 0);
      if v_product.track_stock and v_initial > 0 then
        update app.product_variants set stock_on_hand = v_initial where id = v_target.id;
        insert into app.inventory_movements (store_id, variant_id, delta, resulting_qty, reason, actor_user_id)
        values (p_store_id, v_target.id, v_initial, v_initial, 'initial_stock', v_uid);
      end if;
    end if;
    v_i := v_i + 1;
  end loop;

  -- Variants no longer listed: deleted only when they never held stock.
  select array_agg(v.id) into v_in_use from app.product_variants v
   where v.product_id = p_product_id and not (v.id = any (v_kept))
     and (v.stock_on_hand <> 0 or exists (select 1 from app.inventory_movements m where m.variant_id = v.id));
  if v_in_use is not null then
    perform app.fail('VARIANT_IN_USE', jsonb_build_object('variant_ids', to_jsonb(v_in_use)));
  end if;
  delete from app.product_variants where product_id = p_product_id and not (id = any (v_kept));

  -- SKUs, now that no kept variant holds an old one.
  v_i := 0;
  for v_variant in select * from jsonb_array_elements(p_product -> 'variants') loop
    v_sku := nullif(btrim(coalesce(v_variant ->> 'sku', '')), '');
    if v_sku is not null then
      update app.product_variants set sku = v_sku where id = v_kept[v_i + 1];
    end if;
    v_i := v_i + 1;
  end loop;

  -- Images: the list is the new state (order = position; position 0 is the main image).
  select coalesce(array_agg(storage_path), '{}') into v_old_images
    from app.product_images where product_id = p_product_id;
  delete from app.product_images where product_id = p_product_id;
  insert into app.product_images (store_id, product_id, storage_path, position)
  select p_store_id, p_product_id, path, ord - 1
    from unnest(v_new_images) with ordinality as u(path, ord);

  -- Search text: name, category, option values and SKUs.
  update app.products p set search_text = app.search_normalize(
      p.name || ' ' || coalesce(p.category, '') || ' ' ||
      coalesce((select string_agg(v.label || ' ' || coalesce(v.sku, ''), ' ')
                  from app.product_variants v where v.product_id = p.id), ''))
   where p.id = p_product_id;

  -- Surface a duplicate combination here (the constraint is deferred for in-request swaps).
  set constraints app.product_variants_unique_combination immediate;

  if v_price_changed and not v_is_new then
    perform app.require_permission(p_store_id, 'catalog.price');
  end if;
  v_after := app.product_json(p_product_id);
  v_before := case when v_is_new then null else jsonb_build_object(
    'name', v_existing.name, 'category', v_existing.category, 'base_price', v_existing.base_price,
    'track_stock', v_existing.track_stock, 'status', v_existing.status,
    'option_types', to_jsonb(v_existing.option_types)) end;
  perform app.audit(p_store_id, case when v_is_new then 'product.create' else 'product.update' end,
                    'product', p_product_id, v_before,
                    jsonb_build_object('name', v_after -> 'name', 'category', v_after -> 'category',
                                       'base_price', v_after -> 'base_price',
                                       'track_stock', v_after -> 'track_stock',
                                       'status', v_after -> 'status',
                                       'option_types', v_after -> 'option_types',
                                       'variant_prices', (select jsonb_object_agg(v ->> 'id', v -> 'price')
                                                            from jsonb_array_elements(v_after -> 'variants') v)));

  v_result := app.ok(v_after || jsonb_build_object('removed_image_paths',
    to_jsonb(array(select x from unnest(v_old_images) x where not (x = any (v_new_images))))));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'upsert_product', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name, v_code = message_text;
    if v_constraint = 'product_variants_store_sku' then
      return app.err('VALIDATION_FAILED', '{"fields": {"variants": "sku_duplicate"}}');
    elsif v_constraint = 'product_variants_unique_combination' then
      return app.err('VALIDATION_FAILED', '{"fields": {"variants": "duplicate_combination"}}');
    end if;
    return app.internal_error('upsert_product', '23505', v_code);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text, v_constraint = constraint_name;
    if v_state = '23505' and v_constraint = 'product_variants_unique_combination' then
      return app.err('VALIDATION_FAILED', '{"fields": {"variants": "duplicate_combination"}}');
    end if;
    return app.internal_error('upsert_product', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.set_product_status: active / inactive / archived (BR-17: archive, never hard-delete).
-- Repeating the current status is a harmless no-op, so a retry needs no key.
-- ---------------------------------------------------------------------------------------------
create function api.set_product_status(p_store_id uuid, p_product_id uuid, p_expected_version integer, p_status text)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_product app.products;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_permission(p_store_id, case when p_status = 'archived' then 'catalog.archive' else 'catalog.edit' end);
  if p_status is null or p_status not in ('active', 'inactive', 'archived') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"status": "invalid"}}');
  end if;
  select * into v_product from app.products where id = p_product_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  if v_product.status = p_status then
    return app.ok(app.product_json(p_product_id));
  end if;
  if p_expected_version is distinct from v_product.version then
    perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_product.version));
  end if;
  update app.products set status = p_status, version = version + 1, updated_at = now()
   where id = p_product_id;
  perform app.audit(p_store_id, 'product.status', 'product', p_product_id,
                    jsonb_build_object('status', v_product.status), jsonb_build_object('status', p_status));
  return app.ok(app.product_json(p_product_id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('set_product_status', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.adjust_stock: the only manual way to change stock (Phase 2 PR-05, Phase 3 §6.3).
--   mode add | remove | set; the variant row is locked, so concurrent adjustments serialise and
--   each sees the other's result. p_expected_stock (the number the seller saw) is optional:
--   when given and different, STOCK_CHANGED returns the current stock and nothing changes.
--   The result can never be negative (INSUFFICIENT_STOCK) — BR-14.
-- ---------------------------------------------------------------------------------------------
create function api.adjust_stock(
  p_store_id uuid,
  p_variant_id uuid,
  p_mode text,
  p_quantity integer,
  p_reason text,
  p_note text,
  p_expected_stock integer,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_variant app.product_variants;
  v_product app.products;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_errors jsonb := '{}'::jsonb;
  v_hash text;
  v_result jsonb;
  v_delta integer;
  v_new integer;
  v_movement app.inventory_movements;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'inventory.adjust');
  if p_mode is null or p_mode not in ('add', 'remove', 'set') then
    v_errors := v_errors || '{"mode": "invalid"}';
  end if;
  if p_quantity is null then
    v_errors := v_errors || '{"quantity": "required"}';
  elsif p_quantity < 0 or p_quantity > 1000000 or (p_quantity = 0 and p_mode <> 'set') then
    v_errors := v_errors || '{"quantity": "out_of_range"}';
  end if;
  if p_reason is null or p_reason not in ('received', 'sold_in_shop', 'damaged', 'count_correction', 'other') then
    v_errors := v_errors || '{"reason": "invalid"}';
  elsif p_reason = 'other' and v_note is null then
    v_errors := v_errors || '{"note": "required"}';
  end if;
  if char_length(coalesce(v_note, '')) > 200 then
    v_errors := v_errors || '{"note": "too_long"}';
  end if;
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'variant_id', p_variant_id,
    'mode', p_mode, 'quantity', p_quantity, 'reason', p_reason, 'note', v_note, 'expected', p_expected_stock));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'adjust_stock', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  select * into v_variant from app.product_variants
   where id = p_variant_id and store_id = p_store_id for update;
  if not found then
    perform app.fail('NOT_FOUND');
  end if;
  select * into v_product from app.products where id = v_variant.product_id;
  if not v_product.track_stock then
    perform app.fail('STOCK_NOT_TRACKED');
  end if;
  if v_variant.status <> 'active' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"variant": "archived"}}');
  end if;
  if p_expected_stock is not null and p_expected_stock <> v_variant.stock_on_hand then
    perform app.fail('STOCK_CHANGED', jsonb_build_object('current_stock', v_variant.stock_on_hand));
  end if;

  v_delta := case p_mode when 'add' then p_quantity
                         when 'remove' then -p_quantity
                         else p_quantity - v_variant.stock_on_hand end;
  v_new := v_variant.stock_on_hand + v_delta;
  if v_new < 0 then
    perform app.fail('INSUFFICIENT_STOCK', jsonb_build_object('current_stock', v_variant.stock_on_hand));
  end if;
  if v_new > 1000000 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"quantity": "out_of_range"}}');
  end if;
  if v_delta = 0 then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"quantity": "no_change"}}');
  end if;

  update app.product_variants set stock_on_hand = v_new, updated_at = now() where id = p_variant_id;
  insert into app.inventory_movements (store_id, variant_id, delta, resulting_qty, reason, note, actor_user_id)
  values (p_store_id, p_variant_id, v_delta, v_new, p_reason, v_note, v_uid)
  returning * into v_movement;
  perform app.audit(p_store_id, 'stock.adjust', 'variant', p_variant_id,
                    jsonb_build_object('stock_on_hand', v_variant.stock_on_hand),
                    jsonb_build_object('stock_on_hand', v_new, 'reason', p_reason, 'movement_id', v_movement.id));

  v_result := app.ok(jsonb_build_object(
    'variant_id', p_variant_id,
    'product_id', v_variant.product_id,
    'previous_stock', v_variant.stock_on_hand,
    'stock_on_hand', v_new,
    'movement', jsonb_build_object('id', v_movement.id, 'delta', v_delta, 'resulting_qty', v_new,
                                   'reason', p_reason, 'note', v_note, 'created_at', v_movement.created_at)));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'adjust_stock', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('adjust_stock', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Reads (members only). Stock state per product (Phase 2 §2.4, BR-18):
--   tracked:   out  = every active variant has 0;
--              low  = some active variant is at or below its threshold (store default unless
--                     overridden), including some (not all) at 0;
--              in   = otherwise.
--   untracked: available when any active variant is available, else unavailable.
-- ---------------------------------------------------------------------------------------------
create function app.product_rows(p_store_id uuid)
returns table (
  id uuid, name text, category text, status text, track_stock boolean, base_price integer,
  price_min integer, price_max integer, variant_count integer, stock_total integer,
  low_count integer, out_count integer, stock_state text, image_path text,
  search_text text, updated_at timestamptz, version integer
)
language sql stable
as $$
  select p.id, p.name, p.category, p.status, p.track_stock, p.base_price,
         a.price_min, a.price_max, a.variant_count, a.stock_total, a.low_count, a.out_count,
         case
           when not p.track_stock then case when a.available_count > 0 then 'available' else 'unavailable' end
           when a.variant_count > 0 and a.out_count = a.variant_count then 'out'
           when a.low_count > 0 then 'low'
           else 'in'
         end,
         (select i.storage_path from app.product_images i where i.product_id = p.id order by i.position limit 1),
         p.search_text, p.updated_at, p.version
    from app.products p
    join app.stores s on s.id = p.store_id
    cross join lateral (
      select count(*)::integer as variant_count,
             min(coalesce(v.price_override, p.base_price))::integer as price_min,
             max(coalesce(v.price_override, p.base_price))::integer as price_max,
             coalesce(sum(v.stock_on_hand), 0)::integer as stock_total,
             count(*) filter (where v.stock_on_hand <= coalesce(v.low_stock_threshold, s.low_stock_default))::integer as low_count,
             count(*) filter (where v.stock_on_hand = 0)::integer as out_count,
             count(*) filter (where v.available)::integer as available_count
        from app.product_variants v
       where v.product_id = p.id and v.status = 'active'
    ) a
   where p.store_id = p_store_id;
$$;

-- Catalog page: search (name, category, options, SKU), filter, category, sort, offset paging.
create function api.list_products(
  p_store_id uuid,
  p_query text default null,
  p_filter text default 'all',
  p_category text default null,
  p_sort text default 'updated',
  p_limit integer default 30,
  p_offset integer default 0
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_query text := app.search_normalize(p_query);
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 50);
  v_offset integer := least(greatest(coalesce(p_offset, 0), 0), 100000);
  v_items jsonb;
  v_count integer;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if coalesce(p_filter, 'all') not in ('all', 'low', 'out', 'inactive', 'archived') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"filter": "invalid"}}');
  end if;
  if coalesce(p_sort, 'updated') not in ('updated', 'name', 'price_asc', 'price_desc', 'stock_asc') then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"sort": "invalid"}}');
  end if;
  -- LIKE metacharacters in the query are literal.
  v_query := replace(replace(replace(v_query, '\', '\\'), '%', '\%'), '_', '\_');

  with rows as (
    select r.* from app.product_rows(p_store_id) r
     where case coalesce(p_filter, 'all')
             when 'all' then r.status <> 'archived'
             when 'low' then r.status <> 'archived' and r.stock_state = 'low'
             when 'out' then r.status <> 'archived' and r.stock_state in ('out', 'unavailable')
             when 'inactive' then r.status = 'inactive'
             when 'archived' then r.status = 'archived'
           end
       and (p_category is null or lower(r.category) = lower(btrim(p_category)))
       and (v_query = '' or r.search_text like '%' || v_query || '%')
  ), page as (
    select r.*, row_number() over (order by
             case when coalesce(p_sort, 'updated') = 'name' then lower(r.name) end asc,
             case when p_sort = 'price_asc' then r.price_min end asc,
             case when p_sort = 'price_desc' then r.price_max end desc,
             case when p_sort = 'stock_asc' and r.track_stock then r.stock_total end asc nulls last,
             r.updated_at desc, r.id) as ord
      from rows r
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', id, 'name', name, 'category', category, 'status', status, 'track_stock', track_stock,
           'price_min', price_min, 'price_max', price_max, 'variant_count', variant_count,
           'stock_total', stock_total, 'low_count', low_count, 'out_count', out_count,
           'stock_state', stock_state, 'image_path', image_path, 'updated_at', updated_at,
           'version', version) order by ord) filter (where ord > v_offset and ord <= v_offset + v_limit), '[]'::jsonb),
         count(*)::integer
    into v_items, v_count
    from page;

  return app.ok(jsonb_build_object('items', v_items, 'total', v_count,
                                   'has_more', v_count > v_offset + v_limit));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_products', v_state, v_code);
end;
$$;

-- Counts for the filter chips, the Today attention row and the setup checklist, plus the store's
-- categories (for the category picker and filter).
create function api.catalog_summary(p_store_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_result jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  select jsonb_build_object(
    'total', count(*),
    'all', count(*) filter (where status <> 'archived'),
    'low', count(*) filter (where status <> 'archived' and stock_state = 'low'),
    'out', count(*) filter (where status <> 'archived' and stock_state in ('out', 'unavailable')),
    'inactive', count(*) filter (where status = 'inactive'),
    'archived', count(*) filter (where status = 'archived'),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('name', c.category, 'count', c.n) order by lower(c.category))
        from (select min(category) as category, count(*) as n from app.products
               where store_id = p_store_id and category is not null and status <> 'archived'
               group by lower(category)) c), '[]'::jsonb),
    'low_stock_default', (select low_stock_default from app.stores where id = p_store_id))
    into v_result
    from app.product_rows(p_store_id);
  return app.ok(v_result);
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('catalog_summary', v_state, v_code);
end;
$$;

create function api.get_product(p_store_id uuid, p_product_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if not exists (select 1 from app.products where id = p_product_id and store_id = p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
  return app.ok(app.product_json(p_product_id));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('get_product', v_state, v_code);
end;
$$;

-- Inventory history of a product (Phase 2 PR-06), newest first, keyset-paged by movement id.
create function api.list_inventory_movements(
  p_store_id uuid,
  p_product_id uuid,
  p_variant_id uuid default null,
  p_limit integer default 50,
  p_before_id bigint default null
)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_items jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  if not exists (select 1 from app.products where id = p_product_id and store_id = p_store_id) then
    perform app.fail('NOT_FOUND');
  end if;
  select coalesce(jsonb_agg(m.j order by m.id desc), '[]'::jsonb) into v_items
    from (
      select mv.id, jsonb_build_object(
               'id', mv.id, 'variant_id', mv.variant_id, 'variant_label', v.label,
               'delta', mv.delta, 'resulting_qty', mv.resulting_qty, 'reason', mv.reason,
               'note', mv.note, 'created_at', mv.created_at,
               'actor', case when mv.actor_user_id is null then 'system'
                             when mv.actor_user_id = (select auth.uid()) then 'you'
                             else 'member' end) as j
        from app.inventory_movements mv
        join app.product_variants v on v.id = mv.variant_id
       where v.product_id = p_product_id and mv.store_id = p_store_id
         and (p_variant_id is null or mv.variant_id = p_variant_id)
         and (p_before_id is null or mv.id < p_before_id)
       order by mv.id desc
       limit v_limit + 1
    ) m;
  return app.ok(jsonb_build_object(
    'items', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                select x from jsonb_array_elements(v_items) with ordinality as e(x, o) where o <= v_limit) s),
    'has_more', jsonb_array_length(v_items) > v_limit));
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('list_inventory_movements', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Store settings: the low-stock default becomes editable; the currency cannot change once the
-- store has products (prices are integers in the store currency and are never converted).
-- ---------------------------------------------------------------------------------------------
create or replace function app.store_json(p_store app.stores)
returns jsonb language sql stable
as $$
  select jsonb_build_object(
    'id', p_store.id,
    'name', p_store.name,
    'contact_phone', p_store.contact_phone,
    'currency', p_store.currency,
    'reply_locale', p_store.reply_locale,
    'business_city', p_store.business_city,
    'cod_enabled', p_store.cod_enabled,
    'other_payment_enabled', p_store.other_payment_enabled,
    'onboarding_step', p_store.onboarding_step,
    'currency_locked', p_store.currency_locked_at is not null
                       or exists (select 1 from app.products where store_id = p_store.id),
    'low_stock_default', p_store.low_stock_default,
    'version', p_store.version,
    'created_at', p_store.created_at,
    'updated_at', p_store.updated_at
  );
$$;

create or replace view api.stores with (security_invoker = true) as
  select id, name, contact_phone, currency, reply_locale, business_city, cod_enabled,
         other_payment_enabled, onboarding_step, currency_locked_at is not null as currency_locked,
         version, created_at, updated_at, low_stock_default
  from app.stores;

create or replace function app.store_field_errors(p_fields jsonb)
returns jsonb
language plpgsql immutable
as $$
declare
  v_errors jsonb := '{}'::jsonb;
  v_text text;
  v_num jsonb;
begin
  if p_fields ? 'name' then
    v_text := p_fields ->> 'name';
    if v_text is null or char_length(btrim(v_text)) = 0 then
      v_errors := v_errors || '{"name": "required"}';
    elsif char_length(btrim(v_text)) > 60 then
      v_errors := v_errors || '{"name": "too_long"}';
    end if;
  end if;
  if p_fields ? 'contact_phone' then
    v_text := p_fields ->> 'contact_phone';
    if v_text is null or v_text = '' then
      v_errors := v_errors || '{"contact_phone": "required"}';
    elsif v_text !~ '^\+9647[0-9]{9}$' then
      v_errors := v_errors || '{"contact_phone": "invalid"}';
    end if;
  end if;
  if p_fields ? 'currency' and coalesce(p_fields ->> 'currency', '') not in ('IQD', 'USD') then
    v_errors := v_errors || '{"currency": "invalid"}';
  end if;
  if p_fields ? 'reply_locale' and coalesce(p_fields ->> 'reply_locale', '') not in ('ckb', 'en') then
    v_errors := v_errors || '{"reply_locale": "invalid"}';
  end if;
  if p_fields ? 'business_city' then
    v_text := p_fields ->> 'business_city';
    if v_text is null or char_length(btrim(v_text)) = 0 then
      v_errors := v_errors || '{"business_city": "required"}';
    elsif char_length(btrim(v_text)) > 60 then
      v_errors := v_errors || '{"business_city": "too_long"}';
    end if;
  end if;
  if p_fields ? 'cod_enabled' and jsonb_typeof(p_fields -> 'cod_enabled') <> 'boolean' then
    v_errors := v_errors || '{"cod_enabled": "invalid"}';
  end if;
  if p_fields ? 'other_payment_enabled' and jsonb_typeof(p_fields -> 'other_payment_enabled') <> 'boolean' then
    v_errors := v_errors || '{"other_payment_enabled": "invalid"}';
  end if;
  if p_fields ? 'low_stock_default' then
    v_num := p_fields -> 'low_stock_default';
    if jsonb_typeof(v_num) <> 'number' or (v_num::text)::numeric <> trunc((v_num::text)::numeric)
       or (v_num::text)::numeric not between 0 and 9999 then
      v_errors := v_errors || '{"low_stock_default": "invalid"}';
    end if;
  end if;
  return v_errors;
end;
$$;

create or replace function api.update_store(
  p_store_id uuid,
  p_expected_version integer,
  p_changes jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_allowed text[] := array['name', 'contact_phone', 'currency', 'reply_locale', 'business_city',
                            'cod_enabled', 'other_payment_enabled', 'low_stock_default'];
  v_changes jsonb;
  v_unknown text;
  v_errors jsonb;
  v_hash text;
  v_result jsonb;
  v_old app.stores;
  v_new app.stores;
  v_before jsonb;
  v_after jsonb;
  v_key text;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  perform app.require_permission(p_store_id, 'settings.manage');

  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"changes": "required"}}');
  end if;
  if p_expected_version is null then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"expected_version": "required"}}');
  end if;
  select k into v_unknown from jsonb_object_keys(p_changes) as k where not (k = any (v_allowed)) limit 1;
  if v_unknown is not null then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', jsonb_build_object(v_unknown, 'unknown')));
  end if;

  v_changes := p_changes;
  if v_changes ? 'name' then
    v_changes := jsonb_set(v_changes, '{name}', to_jsonb(btrim(v_changes ->> 'name')));
  end if;
  if v_changes ? 'business_city' then
    v_changes := jsonb_set(v_changes, '{business_city}', to_jsonb(btrim(v_changes ->> 'business_city')));
  end if;
  v_errors := app.store_field_errors(v_changes);
  if v_errors <> '{}'::jsonb then
    perform app.fail('VALIDATION_FAILED', jsonb_build_object('fields', v_errors));
  end if;

  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'version', p_expected_version, 'changes', v_changes));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'update_store', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  select * into v_old from app.stores where id = p_store_id for update;
  if v_old.version <> p_expected_version then
    perform app.fail('CONFLICT_VERSION', jsonb_build_object('current_version', v_old.version));
  end if;
  if v_changes ? 'currency' and v_changes ->> 'currency' <> v_old.currency then
    if v_old.currency_locked_at is not null then
      perform app.fail('CURRENCY_LOCKED');
    end if;
    -- Phase 6 (P6-D3): prices are stored in the store currency; changing it would silently
    -- reinterpret every price, so it is refused once products exist.
    if exists (select 1 from app.products where store_id = p_store_id) then
      perform app.fail('CURRENCY_LOCKED', '{"reason": "products_exist"}');
    end if;
  end if;
  if not (coalesce((v_changes ->> 'cod_enabled')::boolean, v_old.cod_enabled)
          or coalesce((v_changes ->> 'other_payment_enabled')::boolean, v_old.other_payment_enabled)) then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"payment_methods": "at_least_one"}}');
  end if;

  update app.stores set
    name                  = coalesce(v_changes ->> 'name', name),
    contact_phone         = coalesce(v_changes ->> 'contact_phone', contact_phone),
    currency              = coalesce(v_changes ->> 'currency', currency),
    reply_locale          = coalesce(v_changes ->> 'reply_locale', reply_locale),
    business_city         = coalesce(v_changes ->> 'business_city', business_city),
    cod_enabled           = coalesce((v_changes ->> 'cod_enabled')::boolean, cod_enabled),
    other_payment_enabled = coalesce((v_changes ->> 'other_payment_enabled')::boolean, other_payment_enabled),
    low_stock_default     = coalesce((v_changes ->> 'low_stock_default')::integer, low_stock_default),
    version               = version + 1,
    updated_at            = now()
  where id = p_store_id
  returning * into v_new;

  v_before := '{}'::jsonb;
  v_after := '{}'::jsonb;
  for v_key in select jsonb_object_keys(v_changes) loop
    v_before := v_before || jsonb_build_object(v_key, to_jsonb(v_old) -> v_key);
    v_after := v_after || jsonb_build_object(v_key, to_jsonb(v_new) -> v_key);
  end loop;
  perform app.audit(p_store_id, 'store.update', 'store', p_store_id, v_before, v_after);

  v_result := app.ok(app.store_json(v_new));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'update_store', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('update_store', v_state, v_code);
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Storage: private bucket and path policies (Phase 3 authorization §3, NT-07, T-06).
--   Read: members of the store in the first path segment (signed URLs are created with the
--   user's JWT, so the same policy applies). Upload: catalog.edit, exact path shape, JPEG only,
--   ≤ 2 MiB (the app re-encodes to 1600 px, quality 80, without metadata first). No overwrite
--   (no UPDATE policy). Delete: catalog.edit and only when no product references the object.
-- ---------------------------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('store-media', 'store-media', false, 2097152, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg'];

create policy store_media_select on storage.objects
  for select to authenticated
  using (bucket_id = 'store-media' and app.is_member(app.media_store_id(name)));

create policy store_media_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'store-media'
              and app.has_permission(app.media_store_id(name), 'catalog.edit'));

create policy store_media_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'store-media'
         and app.has_permission(app.media_store_id(name), 'catalog.edit')
         and not app.media_referenced(name));

-- Objects in the bucket that no product references (abandoned uploads, removed images, purged
-- accounts), older than p_older_than. Storage objects must be deleted through the Storage API,
-- so this list feeds the cleanup worker (docs/implementation/phase-6, D §5).
create function internal.orphaned_media(p_older_than interval default interval '24 hours')
returns table (name text, created_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select o.name, o.created_at
    from storage.objects o
   where o.bucket_id = 'store-media'
     and o.created_at < now() - p_older_than
     and not exists (select 1 from app.product_images i where i.storage_path = o.name)
   order by o.created_at;
$$;

-- ---------------------------------------------------------------------------------------------
-- Inventory reconciliation (ADR-004, NFR-04): balance = Σ movements for every variant.
-- ---------------------------------------------------------------------------------------------
create function internal.inventory_mismatches()
returns table (variant_id uuid, store_id uuid, stock_on_hand integer, ledger_sum bigint)
language sql stable security definer set search_path = ''
as $$
  select v.id, v.store_id, v.stock_on_hand, coalesce(sum(m.delta), 0)
    from app.product_variants v
    left join app.inventory_movements m on m.variant_id = v.id
   group by v.id
  having v.stock_on_hand <> coalesce(sum(m.delta), 0);
$$;

create function internal.check_inventory_reconciliation()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_count integer;
begin
  select count(*) into v_count from internal.inventory_mismatches();
  if v_count > 0 then
    raise warning 'inventory reconciliation: % variant(s) whose stock differs from the ledger', v_count;
  end if;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Account purge now also removes the catalog (images, ledger, variants, products) before the
-- store. Storage objects of the purged store become orphans for the cleanup worker.
-- ---------------------------------------------------------------------------------------------
create or replace function internal.purge_due_account_deletions()
returns integer
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_request app.account_deletion_requests;
  v_count integer := 0;
begin
  perform set_config('aisellia.purge', 'on', true);
  for v_request in
    select * from app.account_deletion_requests
     where status = 'pending' and execute_after <= now()
     order by execute_after
     for update skip locked
  loop
    if v_request.store_id is not null then
      delete from app.product_images where store_id = v_request.store_id;
      delete from app.inventory_movements where store_id = v_request.store_id;
      delete from app.product_variants where store_id = v_request.store_id;
      delete from app.products where store_id = v_request.store_id;
      delete from app.delivery_zones where store_id = v_request.store_id;
      delete from app.audit_events where store_id = v_request.store_id;
      delete from app.store_members where store_id = v_request.store_id;
      delete from app.stores where id = v_request.store_id;
    end if;
    delete from app.idempotency_keys where user_id = v_request.user_id;
    delete from auth.users where id = v_request.user_id;   -- profiles cascade
    update app.account_deletion_requests
       set status = 'done', executed_at = now()
     where id = v_request.id;
    v_count := v_count + 1;
  end loop;
  perform set_config('aisellia.purge', 'off', true);
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Privileges
-- ---------------------------------------------------------------------------------------------
revoke all on function
  app.protect_ledger(), app.search_normalize(text), app.has_permission(uuid, text),
  app.media_store_id(text), app.media_referenced(text), app.variant_label(text[]),
  app.product_json(uuid), app.require_member(uuid), app.product_field_errors(jsonb, uuid[]),
  app.product_rows(uuid),
  api.upsert_product(uuid, uuid, integer, jsonb, uuid),
  api.set_product_status(uuid, uuid, integer, text),
  api.adjust_stock(uuid, uuid, text, integer, text, text, integer, uuid),
  api.list_products(uuid, text, text, text, text, integer, integer),
  api.catalog_summary(uuid),
  api.get_product(uuid, uuid),
  api.list_inventory_movements(uuid, uuid, uuid, integer, bigint),
  internal.orphaned_media(interval), internal.inventory_mismatches(),
  internal.check_inventory_reconciliation()
from public, anon, authenticated;

-- Storage policies run as the caller: they need these three helpers (all read-only checks).
grant execute on function
  app.has_permission(uuid, text), app.media_store_id(text), app.media_referenced(text)
to authenticated;
grant execute on function
  api.upsert_product(uuid, uuid, integer, jsonb, uuid),
  api.set_product_status(uuid, uuid, integer, text),
  api.adjust_stock(uuid, uuid, text, integer, text, text, integer, uuid),
  api.list_products(uuid, text, text, text, text, integer, integer),
  api.catalog_summary(uuid),
  api.get_product(uuid, uuid),
  api.list_inventory_movements(uuid, uuid, uuid, integer, bigint)
to authenticated;
grant execute on function internal.orphaned_media(interval), internal.inventory_mismatches(),
  internal.check_inventory_reconciliation() to service_role;

-- Nightly reconciliation where pg_cron exists (local stack and hosted Supabase both ship it).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('aisellia-inventory-reconciliation', '41 2 * * *',
                          'select internal.check_inventory_reconciliation()');
  end if;
end $$;
