-- Aisellia — Phase 7: Today figures from real orders (Phase 1 Journey G; Phase 3 contracts §3.8).
--
-- api.order_summary gains the counts the Today screen shows. "Today" is the calendar day in
-- Asia/Baghdad (Iraq, including the Kurdistan Region, has one time zone and no DST; decision P7-D6).
-- Sales figures count committed orders only (approved, processing, dispatched, delivered,
-- delivery_failed) and never test orders (US-043).
create or replace function api.order_summary(p_store_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_day_start timestamptz := date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad';
  v_result jsonb;
  v_code text;
  v_detail text;
  v_state text;
begin
  perform app.require_end_user();
  perform app.require_member(p_store_id);
  select jsonb_build_object(
    'all', count(*) filter (where app.order_matches_filter(o, 'all')),
    'needs_approval', count(*) filter (where app.order_matches_filter(o, 'needs_approval')),
    'drafts', count(*) filter (where app.order_matches_filter(o, 'drafts')),
    'active', count(*) filter (where app.order_matches_filter(o, 'active')),
    'delivered', count(*) filter (where app.order_matches_filter(o, 'delivered')),
    'problems', count(*) filter (where app.order_matches_filter(o, 'problems')),
    'closed', count(*) filter (where app.order_matches_filter(o, 'closed')),
    'test', count(*) filter (where app.order_matches_filter(o, 'test')),
    'to_dispatch', count(*) filter (where not o.is_test and o.status in ('approved', 'processing')),
    'delivery_failed', count(*) filter (where not o.is_test and o.status = 'delivery_failed'),
    'cod_outstanding', coalesce(sum(greatest(o.cod_due - o.cod_collected, 0))
                                filter (where not o.is_test and o.status in ('dispatched', 'delivered')), 0),
    'approved_today', count(*) filter (
      where not o.is_test and o.approved_at >= v_day_start
        and o.status in ('approved', 'processing', 'dispatched', 'delivered', 'delivery_failed')),
    'value_approved_today', coalesce(sum(o.total) filter (
      where not o.is_test and o.approved_at >= v_day_start
        and o.status in ('approved', 'processing', 'dispatched', 'delivered', 'delivery_failed')), 0),
    'delivered_today', count(*) filter (
      where not o.is_test and o.status = 'delivered' and o.status_changed_at >= v_day_start),
    'currency', (select currency from app.stores where id = p_store_id))
    into v_result
    from app.orders o where o.store_id = p_store_id;
  return app.ok(v_result);
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('order_summary', v_state, v_code);
end;
$$;

revoke all on function api.order_summary(uuid) from public, anon, authenticated;
grant execute on function api.order_summary(uuid) to authenticated;
