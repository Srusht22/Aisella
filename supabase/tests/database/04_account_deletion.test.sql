-- Account deletion (Phase 1 US-004, Phase 2 ST-08).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(21);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;
insert into ids values ('a', pg_temp.new_user('leaving@example.test')),
                       ('b', pg_temp.new_user('staying@example.test'));

select pg_temp.act_as((select v from ids where k = 'a'), interval '10 seconds');
insert into ids select 'store_a', (api.create_store('Leaving Shop', '+9647501234567', 'IQD', 'ckb', 'Erbil',
                                                    gen_random_uuid()) #>> '{data,id}')::uuid;
-- Phase 6: the leaving seller has a catalog with stock history (the ledger is append-only).
insert into res select 'pa', api.upsert_product((select v from ids where k = 'store_a'), gen_random_uuid(), null,
  '{"name": "Old stock", "base_price": 1000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 3}], "images": []}', gen_random_uuid());
-- Phase 7: … and an approved order (status history, order movements).
insert into res select 'oa', api.create_order((select v from ids where k = 'store_a'), jsonb_build_object(
  'customer_name', 'Nzar Ahmad', 'customer_phone', '+9647501112233', 'city_text', 'Erbil', 'delivery_fee', 0,
  'area', 'Ankawa', 'payment_method', 'cod',
  'lines', jsonb_build_array(jsonb_build_object('variant_id', (select v #>> '{data,variants,0,id}' from res where k = 'pa'),
                                                'quantity', 1))), gen_random_uuid());
select api.approve_order((select v from ids where k = 'store_a'), (select (v #>> '{data,id}')::uuid from res where k = 'oa'),
                         (select (v #>> '{data,version}')::integer from res where k = 'oa'), '{}', gen_random_uuid())
       #>> '{data,status}' as approved;
select pg_temp.act_as((select v from ids where k = 'b'), interval '10 seconds');
insert into ids select 'store_b', (api.create_store('Staying Shop', '+9647701234567', 'IQD', 'ckb', 'Duhok',
                                                    gen_random_uuid()) #>> '{data,id}')::uuid;
select api.upsert_product((select v from ids where k = 'store_b'), gen_random_uuid(), null,
  '{"name": "Kept stock", "base_price": 1000, "track_stock": true, "status": "active", "option_types": [],
    "variants": [{"option_values": [], "initial_stock": 2}], "images": []}', gen_random_uuid()) is not null as created;
select api.create_order((select v from ids where k = 'store_b'), '{"customer_name": "Kept draft"}', gen_random_uuid())
       is not null as created;

-- Re-authentication is required.
select pg_temp.act_as((select v from ids where k = 'a'));
select is(api.request_account_deletion('Leaving Shop') #>> '{error,code}', 'REAUTHENTICATION_REQUIRED',
          'no password sign-in in the token: refused');
select pg_temp.act_as((select v from ids where k = 'a'), interval '10 minutes');
select is(api.request_account_deletion('Leaving Shop') #>> '{error,code}', 'REAUTHENTICATION_REQUIRED',
          'a password sign-in older than 5 minutes: refused');

-- Confirmation must match the store name.
select pg_temp.act_as((select v from ids where k = 'a'), interval '30 seconds');
select is(api.request_account_deletion('Wrong name') #>> '{error,details,fields,confirm_store_name}', 'mismatch',
          'the typed store name must match');
select is((select count(*)::int from api.stores), 1, 'nothing changed after the refusals');

insert into res select 'req', api.request_account_deletion(' Leaving Shop ');
select is((select v ->> 'ok' from res where k = 'req'), 'true', 'the request is accepted');
select ok(
  (select (v #>> '{data,execute_after}')::timestamptz between now() + interval '13 days 23 hours'
                                                          and now() + interval '14 days 1 hour'
     from res where k = 'req'),
  'data is purged after the 14-day grace period');

-- Access ends immediately.
select is((select count(*)::int from api.stores), 0, 'the store is no longer readable');
select is((select count(*)::int from app.audit_events), 0, 'its audit trail is no longer readable');
select is(api.get_my_context() #>> '{data,deletion_pending}', 'true', 'context reports the pending deletion');
select ok((api.get_my_context() -> 'data' -> 'store') = 'null'::jsonb, 'context returns no store');
select is(
  api.update_store((select v from ids where k = 'store_a'), 1, '{"name": "x"}', gen_random_uuid()) #>> '{error,code}',
  'NOT_FOUND', 'store changes are refused');
select is(
  api.create_store('New Shop', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{error,code}',
  'FORBIDDEN', 'no new store while the deletion is pending');
select is(
  api.request_account_deletion('anything') #>> '{data,execute_after}',
  (select v #>> '{data,execute_after}' from res where k = 'req'),
  'repeating the request returns the same schedule');

-- Users cannot run the purge.
select throws_ok($$ select internal.purge_due_account_deletions() $$, '42501', null,
                 'authenticated users cannot run the purge job');

-- The job purges exactly the due account.
select pg_temp.act_as_admin();
update app.account_deletion_requests set execute_after = now() - interval '1 minute'
 where user_id = (select v from ids where k = 'a');
select is(internal.purge_due_account_deletions(), 1, 'one due account purged');
select ok(
  not exists (select 1 from app.stores where id = (select v from ids where k = 'store_a'))
  and not exists (select 1 from auth.users where id = (select v from ids where k = 'a'))
  and not exists (select 1 from app.profiles where user_id = (select v from ids where k = 'a')),
  'store, auth user and profile are gone');
select ok(
  not exists (select 1 from app.products where store_id = (select v from ids where k = 'store_a'))
  and not exists (select 1 from app.inventory_movements where store_id = (select v from ids where k = 'store_a')),
  'the catalog and its stock history are purged too');
select throws_ok($$ delete from app.inventory_movements $$, 'AS002', null,
                 'outside the purge the ledger is still append-only (the other seller''s history stays)');
select ok(
  not exists (select 1 from app.orders where store_id = (select v from ids where k = 'store_a'))
  and not exists (select 1 from app.order_items where store_id = (select v from ids where k = 'store_a'))
  and not exists (select 1 from app.order_status_events where store_id = (select v from ids where k = 'store_a')),
  'orders, their lines and their status history are purged too');
select throws_ok($$ delete from app.order_status_events $$, 'AS002', null,
                 'outside the purge order history is still append-only');
select ok(
  exists (select 1 from app.stores where id = (select v from ids where k = 'store_b'))
  and exists (select 1 from auth.users where id = (select v from ids where k = 'b')),
  'the other seller is untouched');

select * from finish();
rollback;
