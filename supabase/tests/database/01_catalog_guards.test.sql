-- Catalog-driven guards (Phase 3 authorization §9): these enumerate every table, view and
-- function, so a new object without the required protection fails the suite.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(42);

select is(
  (select array_agg(c.relname order by c.relname) from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'app' and c.relkind = 'r' and not c.relrowsecurity),
  null,
  'every table in app has row-level security enabled'
);

select is(
  (select array_agg(format('%s:%s.%s', r.rolname, c.relname, p.priv) order by format('%s:%s.%s', r.rolname, c.relname, p.priv))
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join (values ('anon'), ('authenticated')) r(rolname)
     cross join (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
    where n.nspname in ('app', 'api') and c.relkind in ('r', 'v')
      and has_table_privilege(r.rolname, c.oid, p.priv)),
  null,
  'anon and authenticated cannot write any table or view directly'
);

select is(
  (select array_agg(c.relname order by c.relname) from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('app', 'api') and c.relkind in ('r', 'v')
      and has_table_privilege('anon', c.oid, 'SELECT')),
  null,
  'anon cannot read any table or view'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'app', 'internal')
      and has_function_privilege('anon', p.oid, 'EXECUTE')),
  null,
  'anon cannot execute any api, app or internal function'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'internal' and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  null,
  'authenticated cannot execute internal functions'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  array['app.has_permission(uuid,text)', 'app.is_member(uuid)', 'app.media_referenced(text)',
        'app.media_store_id(text)'],
  'authenticated can execute only the RLS and storage-policy helpers in app'
);

select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api'
      and not (p.prosecdef and coalesce(p.proconfig, '{}') @> array['search_path=""'])),
  null,
  'every api function is SECURITY DEFINER with an empty search_path'
);

select is(
  (select array_agg(c.relname order by c.relname) from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'api' and c.relkind = 'v'
      and not coalesce(c.reloptions, '{}') @> array['security_invoker=true']),
  null,
  'every api view is security_invoker, so RLS applies to the caller'
);

-- Every api function must appear here AND be covered by an isolation suite (02, 07, 10, 14, 15 or 18).
-- Adding a function without updating both fails this test.
select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'api'),
  array[
    'api.adjust_stock(uuid,uuid,text,integer,text,text,integer,uuid)',
    'api.advance_onboarding(uuid,text)',
    'api.ai_claim_run(uuid)',
    'api.ai_complete_run(uuid,jsonb,jsonb)',
    'api.ai_fail_run(uuid,text,text,jsonb)',
    'api.ai_run_state(uuid)',
    'api.ai_upsert_draft(text,text,jsonb,uuid)',
    'api.ai_usage(uuid,integer)',
    'api.anonymize_customer(uuid,text,uuid)',
    'api.approve_order(uuid,uuid,integer,jsonb,uuid)',
    'api.cancel_order(uuid,uuid,integer,text,text,uuid)',
    'api.cancel_send(uuid,uuid)',
    'api.catalog_summary(uuid)',
    'api.channel_claim_send(uuid)',
    'api.channel_complete_send(uuid,text,text)',
    'api.channel_fail_send(uuid,text,text,integer)',
    'api.channel_ingest_raw(text,text,bytea,jsonb)',
    'api.channel_send_state(uuid)',
    'api.channel_webhook_challenge(text,text)',
    'api.copy_suggestion(uuid,uuid,text,uuid)',
    'api.create_ai_draft_grant(uuid,text,text,integer)',
    'api.create_conversation(uuid,text,text,jsonb,uuid)',
    'api.create_order(uuid,jsonb,uuid)',
    'api.create_store(text,text,text,text,text,uuid)',
    'api.deactivate_zone(uuid,uuid,integer)',
    'api.delete_conversation(uuid,uuid)',
    'api.delete_policy(uuid,uuid,integer)',
    'api.dismiss_suggestion(uuid,uuid)',
    'api.edit_approved_order(uuid,uuid,integer,jsonb,uuid)',
    'api.get_ai_run(uuid,uuid)',
    'api.get_conversation(uuid,uuid)',
    'api.get_my_context()',
    'api.get_order(uuid,uuid)',
    'api.get_product(uuid,uuid)',
    'api.import_messages(uuid,uuid,jsonb,uuid)',
    'api.list_ai_draft_grants(uuid)',
    'api.list_connections(uuid)',
    'api.list_conversations(uuid,text,integer,integer)',
    'api.list_inventory_movements(uuid,uuid,uuid,integer,bigint)',
    'api.list_orders(uuid,text,text,integer,integer)',
    'api.list_policies(uuid)',
    'api.list_products(uuid,text,text,text,text,integer,integer)',
    'api.mark_confirmation_sent(uuid,uuid)',
    'api.mark_message_sent(uuid,uuid)',
    'api.order_confirmation_text(uuid,uuid,text)',
    'api.order_history(uuid,uuid)',
    'api.order_summary(uuid)',
    'api.record_cod(uuid,uuid,bigint,uuid)',
    'api.record_return(uuid,uuid,integer,jsonb,text,uuid)',
    'api.record_seller_reply(uuid,uuid,text,uuid)',
    'api.reject_draft(uuid,uuid,integer,text,text,uuid)',
    'api.request_account_deletion(text)',
    'api.request_ai_assist(uuid,uuid,text,uuid)',
    'api.resolve_unknown_send(uuid,uuid,text,uuid)',
    'api.revoke_ai_draft_grant(uuid,uuid)',
    'api.send_message(uuid,uuid,text,uuid,text,uuid,uuid)',
    'api.set_ai_enabled(uuid,boolean)',
    'api.set_product_status(uuid,uuid,integer,text)',
    'api.transition_order(uuid,uuid,integer,text,jsonb,uuid)',
    'api.update_conversation(uuid,uuid,integer,jsonb)',
    'api.update_draft(uuid,uuid,integer,jsonb,uuid)',
    'api.update_order_note(uuid,uuid,integer,text)',
    'api.update_store(uuid,integer,jsonb,uuid)',
    'api.upsert_policy(uuid,uuid,integer,text,text,boolean,uuid)',
    'api.upsert_product(uuid,uuid,integer,jsonb,uuid)',
    'api.upsert_zone(uuid,uuid,integer,text,integer,text,uuid)'
  ],
  'the api surface is exactly the reviewed list'
);

-- Storage (Phase 3 T-06): product media stay private, JPEG only, small; no overwrite policy.
select is(
  (select row(public, file_size_limit, allowed_mime_types)::text from storage.buckets where id = 'store-media'),
  row(false, 2097152::bigint, array['image/jpeg'])::text,
  'the store-media bucket is private, JPEG only, at most 2 MiB');
select is(
  (select array_agg(policyname::text || ':' || cmd order by policyname) from pg_policies
    where schemaname = 'storage' and tablename = 'objects' and policyname like 'store_media%'),
  array['store_media_delete:DELETE', 'store_media_insert:INSERT', 'store_media_select:SELECT'],
  'store-media has read, upload and delete policies only (no overwrite)');

-- The stock ledger is append-only (BR-64).
select ok(exists (select 1 from pg_trigger where tgname = 'inventory_movements_append_only'
                   and tgrelid = 'app.inventory_movements'::regclass),
          'inventory_movements has the append-only trigger');

-- Orders (Phase 7): history append-only, transitions fixed and enforced on every write.
select ok(exists (select 1 from pg_trigger where tgname = 'order_status_events_append_only'
                   and tgrelid = 'app.order_status_events'::regclass),
          'order_status_events has the append-only trigger');
select ok(exists (select 1 from pg_trigger where tgname = 'orders_status_guard'
                   and tgrelid = 'app.orders'::regclass),
          'orders has the transition guard trigger');
select is((select count(*)::integer from app.order_transitions), 15,
          'the transition table holds exactly the 15 transitions of BR-30');
select is((select array_agg(from_status order by from_status) from app.order_transitions where to_status = 'approved'),
          array['pending_approval'], 'approved is reachable only from pending_approval');
select is((select array_agg(distinct via) from app.order_transitions where to_status = 'approved'),
          array['approve'], '… and only through approve_order');

-- The AI execution role (Phase 8 hardening): one function, no tables, no inherited rights.
select is((select row(rolcanlogin, rolinherit, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb)::text
             from pg_roles where rolname = 'aisellia_ai'),
          row(false, false, false, false, false, false)::text,
          'aisellia_ai cannot log in, inherits nothing and has no special attributes');
select is((select array_agg(b.rolname::text order by b.rolname) from pg_auth_members m
             join pg_roles b on b.oid = m.roleid where m.member = 'aisellia_ai'::regrole),
          null, 'aisellia_ai is a member of no other role (not authenticated, not service_role)');
select is(
  (select array_agg(p.oid::regprocedure::text) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'app', 'internal') and has_function_privilege('aisellia_ai', p.oid, 'EXECUTE')),
  array['api.ai_upsert_draft(text,text,jsonb,uuid)'],
  'aisellia_ai can execute exactly one function: api.ai_upsert_draft');
select is(
  (select array_agg(format('%s.%s:%s', n.nspname, c.relname, p.priv) order by 1) from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
    where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_t%'
      and c.relkind in ('r', 'v', 'm', 'p', 'f')
      -- Effective access needs both: some extensions grant tables to PUBLIC in schemas the role can't enter.
      and has_schema_privilege('aisellia_ai', n.oid, 'USAGE')
      and has_table_privilege('aisellia_ai', c.oid, p.priv)),
  null,
  'aisellia_ai can reach no table or view in any schema (including storage and auth)');
select is(
  (select array_agg(n.nspname::text order by n.nspname) from pg_namespace n
    where has_schema_privilege('aisellia_ai', n.oid, 'USAGE')
      and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_t%'),
  array['api', 'public'],
  'aisellia_ai can enter only api (and public, which holds no tables)');
select is(
  (select array_agg(r order by r) from unnest(array['anon', 'authenticated', 'service_role']) r
    where has_function_privilege(r, 'api.ai_upsert_draft(text,text,jsonb,uuid)', 'EXECUTE')),
  null, 'no other role can execute the AI draft function');
select ok(pg_has_role('authenticator', 'aisellia_ai', 'member'),
          'PostgREST (authenticator) can switch to aisellia_ai for an AI token');

-- The AI worker (Phase 8): its own login, four run functions, no tables, no seller rights.
select is((select row(rolcanlogin, rolinherit, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication)::text
             from pg_roles where rolname = 'aisellia_ai_worker'),
          row(true, false, false, false, false, false, false)::text,
          'aisellia_ai_worker can log in but inherits nothing and has no special attributes');
select is((select array_agg(b.rolname::text order by b.rolname) from pg_auth_members m
             join pg_roles b on b.oid = m.roleid where m.member = 'aisellia_ai_worker'::regrole),
          null, 'aisellia_ai_worker is a member of no other role');
select is(
  (select array_agg(r order by r) from unnest(array['authenticator', 'anon', 'authenticated', 'service_role', 'aisellia_ai']) r
    where pg_has_role(r, 'aisellia_ai_worker', 'member')),
  null, 'no API role (not even PostgREST) can switch to aisellia_ai_worker');
select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'app', 'internal') and has_function_privilege('aisellia_ai_worker', p.oid, 'EXECUTE')),
  array['api.ai_claim_run(uuid)', 'api.ai_complete_run(uuid,jsonb,jsonb)', 'api.ai_fail_run(uuid,text,text,jsonb)',
        'api.ai_run_state(uuid)'],
  'aisellia_ai_worker can execute exactly the four run functions');
select is(
  (select array_agg(format('%s.%s:%s', n.nspname, c.relname, p.priv) order by 1) from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
    where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_t%'
      and c.relkind in ('r', 'v', 'm', 'p', 'f')
      and has_schema_privilege('aisellia_ai_worker', n.oid, 'USAGE')
      and has_table_privilege('aisellia_ai_worker', c.oid, p.priv)),
  null,
  'aisellia_ai_worker can reach no table or view in any schema');
select is(
  (select array_agg(n.nspname::text order by n.nspname) from pg_namespace n
    where has_schema_privilege('aisellia_ai_worker', n.oid, 'USAGE')
      and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_t%'),
  array['api', 'public'],
  'aisellia_ai_worker can enter only api (and public)');
select is(
  (select array_agg(r || ':' || f order by r, f)
     from unnest(array['anon', 'authenticated', 'service_role', 'aisellia_ai']) r
     cross join unnest(array['api.ai_claim_run(uuid)', 'api.ai_complete_run(uuid,jsonb,jsonb)',
                             'api.ai_fail_run(uuid,text,text,jsonb)', 'api.ai_run_state(uuid)']) f
    where has_function_privilege(r, f, 'EXECUTE')),
  null, 'no other role can execute the worker functions');

-- The channel roles (Phase 9 MC-2): their own logins, one function set each, no tables, no seller
-- rights; and no AI role can execute any send or ingest function.
select is((select array_agg(row(rolname, rolcanlogin, rolinherit, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb, rolreplication)::text
                            order by rolname)
             from pg_roles where rolname in ('aisellia_channel_ingest', 'aisellia_channel_sender')),
          array[row('aisellia_channel_ingest', true, false, false, false, false, false, false)::text,
                row('aisellia_channel_sender', true, false, false, false, false, false, false)::text],
          'both channel roles can log in but inherit nothing and have no special attributes');
select is((select array_agg(b.rolname::text order by b.rolname) from pg_auth_members m
             join pg_roles b on b.oid = m.roleid
            where m.member in ('aisellia_channel_ingest'::regrole, 'aisellia_channel_sender'::regrole)),
          null, 'the channel roles are members of no other role');
select is(
  (select array_agg(r || '>' || c order by r, c)
     from unnest(array['authenticator', 'anon', 'authenticated', 'service_role', 'aisellia_ai', 'aisellia_ai_worker']) r
     cross join unnest(array['aisellia_channel_ingest', 'aisellia_channel_sender']) c
    where pg_has_role(r, c, 'member')),
  null, 'no API or AI role can switch to a channel role');
select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'app', 'internal') and has_function_privilege('aisellia_channel_ingest', p.oid, 'EXECUTE')),
  array['api.channel_ingest_raw(text,text,bytea,jsonb)', 'api.channel_webhook_challenge(text,text)'],
  'aisellia_channel_ingest can execute exactly the raw ingest and the handshake check (it cannot store normalised events)');
select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'app', 'internal') and has_function_privilege('aisellia_channel_sender', p.oid, 'EXECUTE')),
  array['api.channel_claim_send(uuid)', 'api.channel_complete_send(uuid,text,text)',
        'api.channel_fail_send(uuid,text,text,integer)', 'api.channel_send_state(uuid)'],
  'aisellia_channel_sender can execute exactly the four send functions');
select is(
  (select array_agg(format('%s:%s.%s:%s', r, n.nspname, c.relname, p.priv) order by 1) from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     cross join unnest(array['aisellia_channel_ingest', 'aisellia_channel_sender']) r
     cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
    where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_t%'
      and c.relkind in ('r', 'v', 'm', 'p', 'f')
      and has_schema_privilege(r, n.oid, 'USAGE')
      and has_table_privilege(r, c.oid, p.priv)),
  null,
  'the channel roles can reach no table or view in any schema (including vault)');
select is(
  (select array_agg(r || ':' || n.nspname::text order by r, n.nspname) from pg_namespace n
     cross join unnest(array['aisellia_channel_ingest', 'aisellia_channel_sender']) r
    where has_schema_privilege(r, n.oid, 'USAGE')
      and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname not like 'pg_t%'),
  array['aisellia_channel_ingest:api', 'aisellia_channel_ingest:public', 'aisellia_channel_sender:api',
        'aisellia_channel_sender:public'],
  'the channel roles can enter only api (and public)');
select is(
  (select array_agg(r || ':' || f order by r, f)
     from unnest(array['anon', 'authenticated', 'service_role', 'aisellia_ai', 'aisellia_ai_worker', 'aisellia_channel_ingest']) r
     cross join unnest(array['api.channel_claim_send(uuid)', 'api.channel_complete_send(uuid,text,text)',
                             'api.channel_fail_send(uuid,text,text,integer)', 'api.channel_send_state(uuid)']) f
    where has_function_privilege(r, f, 'EXECUTE')),
  null, 'no role other than the sender (and never an AI role) can execute the send-execution functions');
select is(
  (select array_agg(r || ':' || f order by r, f)
     from unnest(array['anon', 'aisellia_ai', 'aisellia_ai_worker', 'aisellia_channel_ingest', 'aisellia_channel_sender']) r
     cross join unnest(array['api.send_message(uuid,uuid,text,uuid,text,uuid,uuid)', 'api.resolve_unknown_send(uuid,uuid,text,uuid)',
                             'api.cancel_send(uuid,uuid)']) f
    where has_function_privilege(r, f, 'EXECUTE')),
  null, 'no AI or machine role can authorize, resend or cancel a message: only signed-in sellers');
select is(
  (select array_agg(r order by r) from unnest(array['anon', 'authenticated', 'service_role', 'aisellia_ai', 'aisellia_ai_worker',
                                                     'aisellia_channel_sender']) r
    where has_function_privilege(r, 'api.channel_ingest_raw(text,text,bytea,jsonb)', 'EXECUTE')
       or (r <> 'service_role' and has_function_privilege(r, 'internal.channel_store_events(text,text,text,jsonb,text)', 'EXECUTE'))),
  null, 'no role other than the ingest role can hand in webhooks, and only the service role can store normalised events');
select is(
  (select array_agg(p.oid::regprocedure::text order by 1) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('api', 'app', 'internal')
      and (has_function_privilege('aisellia_ai_worker', p.oid, 'EXECUTE') or has_function_privilege('aisellia_ai', p.oid, 'EXECUTE'))
      and p.proname in ('approve_order', 'transition_order', 'edit_approved_order', 'send_message', 'channel_claim_send',
                        'channel_complete_send', 'resolve_unknown_send', 'mark_confirmation_sent')),
  null, 'neither AI role can approve or advance an order, or send, resend or confirm a message');

select * from finish();
rollback;
