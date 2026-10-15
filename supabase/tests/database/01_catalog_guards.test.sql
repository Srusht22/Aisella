-- Catalog-driven guards (Phase 3 authorization §9): these enumerate every table, view and
-- function, so a new object without the required protection fails the suite.
begin;
create extension if not exists pgtap with schema extensions;
\ir _helpers.psql
select plan(9);

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
  array['app.is_member(uuid)'],
  'authenticated can execute only the RLS membership helper in app'
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

-- Every api function must appear here AND be covered by 02_tenant_isolation. Adding a
-- function without updating both fails this test.
select is(
  (select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text) from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'api'),
  array[
    'api.advance_onboarding(uuid,text)',
    'api.create_store(text,text,text,text,text,uuid)',
    'api.deactivate_zone(uuid,uuid,integer)',
    'api.get_my_context()',
    'api.request_account_deletion(text)',
    'api.update_store(uuid,integer,jsonb,uuid)',
    'api.upsert_zone(uuid,uuid,integer,text,integer,text,uuid)'
  ],
  'the api surface is exactly the reviewed list'
);

select * from finish();
rollback;
