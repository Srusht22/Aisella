-- Negative authorization tests (Phase 3 authorization §9: NT-01..04, NT-06, NT-10) for the
-- Phase 5 surface. Two sellers (A, B), the anonymous role and the service role.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(27);

create temp table ids (k text primary key, v uuid);
grant all on ids to public;

insert into ids values ('a', pg_temp.new_user('seller-a@example.test')),
                       ('b', pg_temp.new_user('seller-b@example.test'));

-- A creates a store and a zone.
select pg_temp.act_as((select v from ids where k = 'a'));
insert into ids
select 'store_a', (api.create_store('Shilan Boutique', '+9647501234567', 'IQD', 'ckb', 'Sulaymaniyah',
                                    gen_random_uuid()) -> 'data' ->> 'id')::uuid;
insert into ids
select 'zone_a', (api.upsert_zone((select v from ids where k = 'store_a'), null, null, 'Erbil', 5000, null,
                                  gen_random_uuid()) -> 'data' ->> 'id')::uuid;
select isnt((select v from ids where k = 'store_a'), null, 'A created a store');
select isnt((select v from ids where k = 'zone_a'), null, 'A created a zone');

-- ---- B: no access to A ------------------------------------------------------------------
select pg_temp.act_as((select v from ids where k = 'b'));

select is((select count(*)::int from api.stores), 0, 'NT-01 B sees no stores through api.stores');
select is((select count(*)::int from api.delivery_zones), 0, 'NT-01 B sees no zones through api.delivery_zones');
select is((select count(*)::int from app.stores), 0, 'NT-01 B sees no rows in app.stores (RLS)');
select is((select count(*)::int from app.store_members), 0, 'NT-01 B sees no memberships');
select is((select count(*)::int from app.audit_events), 0, 'NT-01 B sees no audit events');
select is((select count(*)::int from app.profiles), 1, 'NT-01 B sees only their own profile');

select is(
  api.update_store((select v from ids where k = 'store_a'), 1, '{"name": "Taken over"}', gen_random_uuid()) #>> '{error,code}',
  'NOT_FOUND', 'NT-02 B cannot update A''s store (NOT_FOUND, no existence leak)');
select is(
  api.upsert_zone((select v from ids where k = 'store_a'), null, null, 'Duhok', 1, null, gen_random_uuid()) #>> '{error,code}',
  'NOT_FOUND', 'NT-02 B cannot add a zone to A''s store');
select is(
  api.upsert_zone((select v from ids where k = 'store_a'), (select v from ids where k = 'zone_a'), 1, 'Erbil', 0, null, gen_random_uuid()) #>> '{error,code}',
  'NOT_FOUND', 'NT-02 B cannot edit A''s zone');
select is(
  api.deactivate_zone((select v from ids where k = 'store_a'), (select v from ids where k = 'zone_a'), 1) #>> '{error,code}',
  'NOT_FOUND', 'NT-02 B cannot remove A''s zone');
select is(
  api.advance_onboarding((select v from ids where k = 'store_a'), 'done') #>> '{error,code}',
  'NOT_FOUND', 'NT-02 B cannot advance A''s onboarding');
select is(
  api.update_store(gen_random_uuid(), 1, '{"name": "x"}', gen_random_uuid()) #>> '{error,code}',
  'NOT_FOUND', 'NT-02 a random store id gives the same NOT_FOUND as A''s');
select ok(
  (api.get_my_context() -> 'data' -> 'store') = 'null'::jsonb,
  'B''s context has no store');

-- NT-06: B's own store with A's zone id (mixed references).
insert into ids
select 'store_b', (api.create_store('Dara Cosmetics', '+9647701234567', 'USD', 'en', 'Erbil',
                                    gen_random_uuid()) -> 'data' ->> 'id')::uuid;
select is(
  api.upsert_zone((select v from ids where k = 'store_b'), (select v from ids where k = 'zone_a'), 1, 'Stolen', 0, null, gen_random_uuid()) #>> '{error,code}',
  'NOT_FOUND', 'NT-06 B cannot reach A''s zone through B''s own store id');
select is(
  api.deactivate_zone((select v from ids where k = 'store_b'), (select v from ids where k = 'zone_a'), 1) #>> '{error,code}',
  'NOT_FOUND', 'NT-06 B cannot remove A''s zone through B''s own store id');

-- NT-10 / NT-03: no direct writes, even to one's own rows.
select throws_ok(
  $$ update app.stores set name = 'Direct write' where id = (select v from ids where k = 'store_b') $$,
  '42501', null, 'NT-10 B cannot UPDATE app.stores directly');
select throws_ok(
  $$ insert into app.store_members (store_id, user_id, role)
     values ((select v from ids where k = 'store_a'), (select v from ids where k = 'b'), 'owner') $$,
  '42501', null, 'NT-03 B cannot make themselves a member of A''s store');
select throws_ok(
  $$ delete from app.delivery_zones $$,
  '42501', null, 'NT-03 B cannot DELETE zones directly');
select throws_ok(
  $$ update api.stores set name = 'Via view' $$,
  '42501', null, 'NT-10 B cannot write through the api.stores view');

-- ---- Anonymous --------------------------------------------------------------------------
select pg_temp.act_as_anon();
select throws_ok($$ select * from api.stores $$, '42501', null, 'NT-04 anon cannot read api.stores');
select throws_ok($$ select api.get_my_context() $$, '42501', null, 'NT-04 anon cannot call get_my_context');
select throws_ok(
  $$ select api.create_store('Anon', '+9647501111111', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) $$,
  '42501', null, 'NT-04 anon cannot create a store');

-- ---- Service role: not an end user ------------------------------------------------------
select pg_temp.act_as_admin();
set local role service_role;
select throws_ok(
  $$ select api.update_store((select v from ids where k = 'store_a'), 1, '{"name": "x"}', gen_random_uuid()) $$,
  '42501', null, 'NT-05 service_role cannot call api mutations');

-- ---- A's data is unchanged by everything above ------------------------------------------
select pg_temp.act_as_admin();
select is((select name from app.stores where id = (select v from ids where k = 'store_a')),
          'Shilan Boutique', 'A''s store name is unchanged');
select is((select count(*)::int from app.store_members where store_id = (select v from ids where k = 'store_a')),
          1, 'A''s store still has exactly one member');

select * from finish();
rollback;
