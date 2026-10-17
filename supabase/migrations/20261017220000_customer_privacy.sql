-- Aisellia — customer privacy safeguards for orders and their audit trail.
--
-- Phase 3 §7.1–7.2 and Phase 1 BR-72: customer contact data is kept while needed for the order and
-- removed on the seller's request; audit rows keep accountability but their personal values are
-- anonymised with the customer. Before this migration the audit kept full names and phone numbers
-- indefinitely and nothing could remove them. Now:
--   * Minimisation: order audit rows store phone numbers masked (+964750***2233).
--   * Erasure: api.anonymize_customer (owner only) clears a customer's contact data from that
--     store's delivered or closed orders, redacts those values in the orders' audit rows and deletes
--     stored idempotency responses that contain them. Totals, lines, stock movements and status
--     history stay (BR-72: "financial facts remain"). Orders still in progress are skipped and
--     reported, so a delivery is never broken.
--   * Integrity: audit_events becomes append-only; the only exceptions are this redaction (values
--     only, flagged by a transaction setting) and the account purge.

alter table app.orders add column customer_anonymized_at timestamptz;

-- ---------------------------------------------------------------------------------------------
-- Audit integrity
-- ---------------------------------------------------------------------------------------------
create function app.protect_audit()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('aisellia.purge', true), '') = 'on' then
    return old;
  end if;
  if tg_op = 'UPDATE' and coalesce(current_setting('aisellia.redact', true), '') = 'on'
     and new.id = old.id and new.store_id = old.store_id and new.action = old.action
     and new.entity_type = old.entity_type and new.entity_id is not distinct from old.entity_id
     and new.actor_user_id is not distinct from old.actor_user_id and new.created_at = old.created_at then
    return new;
  end if;
  raise exception 'audit_events is append-only (%)', tg_op using errcode = 'AS002';
end;
$$;
create trigger audit_events_append_only
  before update or delete on app.audit_events
  for each row execute function app.protect_audit();

-- ---------------------------------------------------------------------------------------------
-- Minimisation: masked phones in order audit rows.
-- ---------------------------------------------------------------------------------------------
create function app.mask_phone(p_phone text)
returns text language sql immutable
as $$
  select case when p_phone is null then null
              when char_length(p_phone) <= 8 then '***'
              else left(p_phone, 7) || '***' || right(p_phone, 4) end;
$$;

-- Diffs are computed on the real values (so a changed phone is still recorded as a change, even
-- when both masked forms look alike); the masking happens as the audit row is written.
create function app.mask_audit_phones(p_values jsonb)
returns jsonb language sql immutable
as $$
  select case when p_values is null or jsonb_typeof(p_values) <> 'object' then p_values
         else p_values || coalesce((
           select jsonb_object_agg(k, app.mask_phone(p_values ->> k))
             from unnest(array['customer_phone', 'customer_phone2']) k
            where jsonb_typeof(p_values -> k) = 'string'), '{}'::jsonb) end;
$$;

create function app.minimise_audit()
returns trigger
language plpgsql
as $$
begin
  if new.entity_type = 'order' then
    new.before := app.mask_audit_phones(new.before);
    new.after := app.mask_audit_phones(new.after);
  end if;
  return new;
end;
$$;
create trigger audit_events_minimise
  before insert on app.audit_events
  for each row execute function app.minimise_audit();

-- Personal values in an audit before/after object, replaced by a marker.
create function app.redact_customer(p_values jsonb)
returns jsonb language sql immutable
as $$
  select case when p_values is null or jsonb_typeof(p_values) <> 'object' then p_values
         else p_values || coalesce((
           select jsonb_object_agg(k, '[redacted]')
             from unnest(array['customer_name', 'customer_phone', 'customer_phone2', 'area', 'landmark',
                               'address_details', 'customer_note']) k
            where p_values ? k and jsonb_typeof(p_values -> k) <> 'null'), '{}'::jsonb) end;
$$;

-- ---------------------------------------------------------------------------------------------
-- api.anonymize_customer: the seller's "delete this customer" (BR-72), by phone number.
-- ---------------------------------------------------------------------------------------------
create function api.anonymize_customer(p_store_id uuid, p_phone text, p_idempotency_key uuid)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_uid uuid;
  v_member app.store_members;
  v_phone text := btrim(coalesce(p_phone, ''));
  v_hash text;
  v_result jsonb;
  v_done uuid[];
  v_skipped integer;
  v_id uuid;
  v_code text;
  v_detail text;
  v_state text;
begin
  v_uid := app.require_end_user();
  v_member := app.require_permission(p_store_id, 'customers.delete');
  if v_member.role <> 'owner' then
    perform app.fail('FORBIDDEN');
  end if;
  if v_phone !~ '^\+9647[0-9]{9}$' then
    perform app.fail('VALIDATION_FAILED', '{"fields": {"phone": "invalid"}}');
  end if;
  -- The request names the customer, so only its hash is kept with the key.
  v_hash := app.request_hash(jsonb_build_object('store_id', p_store_id, 'phone_hash', app.secret_hash(v_phone)));
  v_result := app.idempotency_replay(v_uid, p_idempotency_key, 'anonymize_customer', v_hash);
  if v_result is not null then
    return v_result;
  end if;

  -- Orders still being handled keep their contact data until they are delivered or closed.
  select count(*) into v_skipped from app.orders
   where store_id = p_store_id and customer_anonymized_at is null
     and (customer_phone = v_phone or customer_phone2 = v_phone)
     and status not in ('delivered', 'rejected', 'cancelled', 'returned');

  select coalesce(array_agg(id order by number), '{}') into v_done from (
    select id, number from app.orders
     where store_id = p_store_id and customer_anonymized_at is null
       and (customer_phone = v_phone or customer_phone2 = v_phone)
       and status in ('delivered', 'rejected', 'cancelled', 'returned')
     order by id for update) s;

  update app.orders set customer_name = null, customer_phone = null, customer_phone2 = null, area = null,
                        landmark = null, address_details = null, customer_note = null,
                        customer_anonymized_at = now(), version = version + 1, updated_at = now()
   where id = any (v_done);
  foreach v_id in array v_done loop
    perform app.order_recompute(v_id);   -- search fields no longer hold the name or phone
  end loop;

  perform set_config('aisellia.redact', 'on', true);
  update app.audit_events
     set before = app.redact_customer(before), after = app.redact_customer(after)
   where store_id = p_store_id and entity_type = 'order' and entity_id = any (v_done);
  perform set_config('aisellia.redact', 'off', true);

  -- Stored answers of earlier requests repeat the contact data: they go too.
  delete from app.idempotency_keys
   where response -> 'data' ->> 'id' = any (array(select x::text from unnest(v_done) x))
      or response -> 'data' ->> 'order_id' = any (array(select x::text from unnest(v_done) x));

  perform app.audit(p_store_id, 'customer.anonymize', 'store', p_store_id, null,
                    jsonb_build_object('orders', cardinality(v_done), 'skipped_in_progress', v_skipped));

  v_result := app.ok(jsonb_build_object('anonymized', cardinality(v_done), 'skipped_in_progress', v_skipped,
                                        'order_ids', to_jsonb(v_done)));
  perform app.idempotency_save(v_uid, p_idempotency_key, 'anonymize_customer', v_hash, v_result);
  return v_result;
exception
  when sqlstate 'AS001' then
    get stacked diagnostics v_code = message_text, v_detail = pg_exception_detail;
    return app.err(v_code, v_detail::jsonb);
  when others then
    get stacked diagnostics v_state = returned_sqlstate, v_code = message_text;
    return app.internal_error('anonymize_customer', v_state, v_code);
end;
$$;

revoke all on function app.protect_audit(), app.mask_phone(text), app.mask_audit_phones(jsonb),
  app.minimise_audit(), app.redact_customer(jsonb),
  api.anonymize_customer(uuid, text, uuid)
from public, anon, authenticated, aisellia_ai;
grant execute on function api.anonymize_customer(uuid, text, uuid) to authenticated;
