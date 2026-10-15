-- Store, onboarding and zone rules (Phase 1 US-005, US-006, US-008; Phase 3 ADR-005).
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(41);

create temp table ids (k text primary key, v uuid);
create temp table res (k text primary key, v jsonb);
grant all on ids, res to public;

insert into ids values ('a', pg_temp.new_user('owner@example.test')), ('key1', gen_random_uuid());

-- ---- Profile created at sign-up --------------------------------------------------------
select is((select terms_version from app.profiles where user_id = (select v from ids where k = 'a')),
          '2026-10', 'sign-up trigger records the accepted terms version');

select pg_temp.act_as((select v from ids where k = 'a'));

-- ---- Context before a store -----------------------------------------------------------
select is(api.get_my_context() #>> '{data,email}', 'owner@example.test', 'context returns the email');
select is(api.get_my_context() #>> '{data,email_verified}', 'true', 'context reports email verification');
select ok((api.get_my_context() -> 'data' -> 'store') = 'null'::jsonb, 'no store yet');

-- ---- create_store validation (nothing created) -----------------------------------------
select is(
  api.create_store('   ', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{error,details,fields,name}',
  'required', 'blank name is rejected');
select is(
  api.create_store(repeat('x', 61), '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{error,details,fields,name}',
  'too_long', 'a 61-character name is rejected');
select is(
  api.create_store('Shop', '07501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{error,details,fields,contact_phone}',
  'invalid', 'a phone that is not normalised E.164 Iraqi mobile is rejected');
select is(
  api.create_store('Shop', '+9647501234567', 'EUR', 'fr', '', gen_random_uuid()) -> 'error' -> 'details' -> 'fields',
  '{"currency": "invalid", "reply_locale": "invalid", "business_city": "required"}'::jsonb,
  'every invalid field is reported at once');
select is(
  api.create_store('Shop', '+9647501234567', 'IQD', 'ckb', 'Erbil', null) #>> '{error,details,fields,idempotency_key}',
  'required', 'an idempotency key is required');
select is((select count(*)::int from api.stores), 0, 'failed attempts created nothing');

-- ---- create_store success, replay, reuse, limit ----------------------------------------
insert into res select 'created', api.create_store('  Shilan Boutique ', '+9647501234567', 'IQD', 'ckb', 'Sulaymaniyah',
                                                   (select v from ids where k = 'key1'));
select is((select v ->> 'ok' from res where k = 'created'), 'true', 'store created');
select is((select v #>> '{data,name}' from res where k = 'created'), 'Shilan Boutique', 'name is trimmed');
select is((select v #>> '{data,onboarding_step}' from res where k = 'created'), 'zones', 'onboarding resumes at zones');
insert into ids select 'store', (v #>> '{data,id}')::uuid from res where k = 'created';

select is(
  api.create_store('  Shilan Boutique ', '+9647501234567', 'IQD', 'ckb', 'Sulaymaniyah', (select v from ids where k = 'key1')),
  (select v from res where k = 'created'),
  'a retry with the same key replays the original result');
select is((select count(*)::int from api.stores), 1, 'the replay did not create a second store');
select is(
  api.create_store('Other name', '+9647501234567', 'IQD', 'ckb', 'Sulaymaniyah', (select v from ids where k = 'key1')) #>> '{error,code}',
  'IDEMPOTENCY_KEY_REUSED', 'the same key with a different request is refused');
select is(
  api.create_store('Second shop', '+9647501234567', 'IQD', 'ckb', 'Erbil', gen_random_uuid()) #>> '{error,code}',
  'LIMIT_EXCEEDED', 'P0: a second store for the same user is refused');
select is(api.get_my_context() #>> '{data,role}', 'owner', 'the creator is the owner');
select is(api.get_my_context() #>> '{data,store,id}', (select v::text from ids where k = 'store'), 'context returns the store');

-- ---- update_store ----------------------------------------------------------------------
select is(
  api.update_store((select v from ids where k = 'store'), 1, '{"name": "Shilan Shop", "reply_locale": "en"}', gen_random_uuid()) #>> '{data,version}',
  '2', 'a valid update increments the version');
select is((select reply_locale from api.stores), 'en', 'the change is persisted');
select is(
  api.update_store((select v from ids where k = 'store'), 1, '{"name": "Stale"}', gen_random_uuid()) -> 'error',
  '{"code": "CONFLICT_VERSION", "details": {"current_version": 2}}'::jsonb,
  'a stale version is a conflict with the current version');
select is(
  api.update_store((select v from ids where k = 'store'), 2, '{"owner_id": "x"}', gen_random_uuid()) #>> '{error,details,fields,owner_id}',
  'unknown', 'fields outside the allow-list are rejected');
select is(
  api.update_store((select v from ids where k = 'store'), 2, '{}', gen_random_uuid()) #>> '{error,code}',
  'VALIDATION_FAILED', 'an empty change set is rejected');
select is(
  api.update_store((select v from ids where k = 'store'), 2, '{"cod_enabled": false}', gen_random_uuid()) #>> '{error,details,fields,payment_methods}',
  'at_least_one', 'turning off the only payment method is rejected');
select is(
  api.update_store((select v from ids where k = 'store'), 2, '{"cod_enabled": "no"}', gen_random_uuid()) #>> '{error,details,fields,cod_enabled}',
  'invalid', 'non-boolean switches are rejected');
select is(
  api.update_store((select v from ids where k = 'store'), 2, '{"other_payment_enabled": true, "cod_enabled": false}', gen_random_uuid()) #>> '{data,cod_enabled}',
  'false', 'switching payment methods together is allowed');
select is(
  (select after from app.audit_events where action = 'store.update' order by id desc limit 1),
  '{"cod_enabled": false, "other_payment_enabled": true}'::jsonb,
  'the update is audited with only the changed fields');

-- Currency lock (set by the first approved order in a later phase).
select pg_temp.act_as_admin();
update app.stores set currency_locked_at = now() where id = (select v from ids where k = 'store');
select pg_temp.act_as((select v from ids where k = 'a'));
select is(
  api.update_store((select v from ids where k = 'store'), 3, '{"currency": "USD"}', gen_random_uuid()) #>> '{error,code}',
  'CURRENCY_LOCKED', 'currency cannot change once locked');
select is(
  api.update_store((select v from ids where k = 'store'), 3, '{"currency": "IQD"}', gen_random_uuid()) ->> 'ok',
  'true', 'sending the unchanged currency is still allowed');

-- ---- Zones -----------------------------------------------------------------------------
insert into res select 'zone', api.upsert_zone((select v from ids where k = 'store'), null, null, ' Erbil ', 5000, '1-2 days', gen_random_uuid());
select is((select v #>> '{data,name}' from res where k = 'zone'), 'Erbil', 'zone created with a trimmed name');
select is(
  api.upsert_zone((select v from ids where k = 'store'), null, null, 'erbil', 3000, null, gen_random_uuid()) #>> '{error,details,fields,name}',
  'duplicate', 'zone names are unique per store, case-insensitively');
select is(
  api.upsert_zone((select v from ids where k = 'store'), null, null, 'Duhok', -1, null, gen_random_uuid()) #>> '{error,details,fields,fee}',
  'out_of_range', 'a negative fee is rejected');
select is(
  api.upsert_zone((select v from ids where k = 'store'), ((select v from res where k = 'zone') #>> '{data,id}')::uuid, 1, 'Erbil', 6000, null, gen_random_uuid()) #>> '{data,fee}',
  '6000', 'a zone fee can be edited with the current version');
select is(
  api.upsert_zone((select v from ids where k = 'store'), ((select v from res where k = 'zone') #>> '{data,id}')::uuid, 1, 'Erbil', 7000, null, gen_random_uuid()) #>> '{error,code}',
  'CONFLICT_VERSION', 'editing with a stale zone version is a conflict');
select is(
  api.deactivate_zone((select v from ids where k = 'store'), ((select v from res where k = 'zone') #>> '{data,id}')::uuid, 2) #>> '{data,active}',
  'false', 'a zone can be removed (deactivated)');
select is(
  api.deactivate_zone((select v from ids where k = 'store'), ((select v from res where k = 'zone') #>> '{data,id}')::uuid, 2) ->> 'ok',
  'true', 'removing it again is a harmless no-op');
select is(
  api.upsert_zone((select v from ids where k = 'store'), null, null, 'Erbil', 4000, null, gen_random_uuid()) ->> 'ok',
  'true', 'a removed zone''s name can be used again');

-- ---- Onboarding ------------------------------------------------------------------------
select is(api.advance_onboarding((select v from ids where k = 'store'), 'payments') #>> '{data,onboarding_step}',
          'payments', 'onboarding advances to payments');
select is(api.advance_onboarding((select v from ids where k = 'store'), 'done') #>> '{data,onboarding_step}',
          'done', 'onboarding completes');
select is(api.advance_onboarding((select v from ids where k = 'store'), 'payments') #>> '{data,onboarding_step}',
          'done', 'onboarding never moves backwards');

select * from finish();
rollback;
