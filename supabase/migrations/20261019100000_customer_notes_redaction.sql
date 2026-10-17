-- Aisellia — Phase 8.5: "delete this customer" also reaches the seller's free-text notes.
--
-- Until now api.anonymize_customer cleared the customer's own fields but left the seller-written
-- notes (internal, courier, payment, closing, status-change notes), which can repeat the
-- customer's name or number: "Nzar called from 0750 111 2233, leave at the gate". Now, for every
-- order being anonymised:
--   * the customer's name (whole and each word of 3+ letters) and phone numbers (any common
--     writing: 07…, +964…, 00964…, spaces or dashes, Western, Arabic or Persian digits) are
--     replaced with "[redacted]" inside those notes, in the order's status history and in its
--     audit rows; the rest of the note stays (it is the seller's business record);
--   * orders anonymised earlier, whose names are already gone, have the requested phone number
--     redacted from their notes as well.
-- Nothing is deleted. Status history stays append-only: only the note may change, and only inside
-- this function (the same redaction flag the audit log already honours).

-- ---------------------------------------------------------------------------------------------
-- Text redaction
-- ---------------------------------------------------------------------------------------------
create function app.redact_contact_text(p_text text, p_name text, p_phones text[])
returns text
language plpgsql immutable
as $$
declare
  v text := p_text;
  v_phone text;
  v_core text;
  v_word text;
  v_rx text;
begin
  if v is null then
    return null;
  end if;
  -- Phone numbers: the 10 national digits (7XXXXXXXXX) with optional separators, any digit script,
  -- and an optional 0 / 964 / +964 / 00964 prefix.
  foreach v_phone in array coalesce(p_phones, '{}') loop
    continue when v_phone is null or v_phone !~ '^\+9647[0-9]{9}$';
    select string_agg(format('[%s%s%s]', d, chr(1632 + d::integer), chr(1776 + d::integer)), '[\s.-]?' order by n)
      into v_core from regexp_split_to_table(substr(v_phone, 5), '') with ordinality t(d, n);
    v_rx := '(?<![0-9٠-٩۰-۹])((\+|00)?[9٩۹][6٦۶][4٤۴][\s.-]?|[0٠۰][\s.-]?)?' || v_core || '(?![0-9٠-٩۰-۹])';
    v := regexp_replace(v, v_rx, '[redacted]', 'g');
  end loop;
  -- The name, then each of its words of three letters or more. Latin words must end at a word
  -- boundary ("Ali" leaves "Alice"); Arabic-script words may carry a suffix ("نزارەکە").
  if char_length(btrim(coalesce(p_name, ''))) >= 3 then
    foreach v_word in array array[btrim(p_name)] || regexp_split_to_array(btrim(p_name), '\s+') loop
      continue when char_length(v_word) < 3;
      v_rx := '\m' || regexp_replace(v_word, '([.^$*+?(){}|\[\]\\])', '\\\1', 'g')
              || case when v_word ~* '[a-z0-9]$' then '\M' else '' end;
      v := regexp_replace(v, v_rx, '[redacted]', 'gi');
    end loop;
  end if;
  return v;
end;
$$;

create function app.redact_contact_json(p_value jsonb, p_name text, p_phones text[])
returns jsonb
language plpgsql immutable
as $$
begin
  return case jsonb_typeof(p_value)
    when 'string' then to_jsonb(app.redact_contact_text(p_value #>> '{}', p_name, p_phones))
    when 'object' then coalesce((select jsonb_object_agg(k, app.redact_contact_json(v, p_name, p_phones))
                                   from jsonb_each(p_value) e(k, v)), '{}'::jsonb)
    when 'array' then coalesce((select jsonb_agg(app.redact_contact_json(v, p_name, p_phones) order by o)
                                  from jsonb_array_elements(p_value) with ordinality a(v, o)), '[]'::jsonb)
    else p_value end;
end;
$$;

-- ---------------------------------------------------------------------------------------------
-- Status history: append-only, except a note redacted by anonymize_customer.
-- ---------------------------------------------------------------------------------------------
create function app.protect_status_events()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and coalesce(current_setting('aisellia.purge', true), '') = 'on' then
    return old;
  end if;
  if tg_op = 'UPDATE' and coalesce(current_setting('aisellia.redact', true), '') = 'on'
     and to_jsonb(new) - 'note' = to_jsonb(old) - 'note' then
    return new;
  end if;
  raise exception '% is append-only (%)', tg_table_name, tg_op using errcode = 'AS002';
end;
$$;
drop trigger order_status_events_append_only on app.order_status_events;
create trigger order_status_events_append_only
  before update or delete on app.order_status_events
  for each row execute function app.protect_status_events();

-- ---------------------------------------------------------------------------------------------
-- api.anonymize_customer (from 20261018100000_ai_assist), now with notes.
-- ---------------------------------------------------------------------------------------------
create or replace function api.anonymize_customer(p_store_id uuid, p_phone text, p_idempotency_key uuid)
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
  v_prior uuid[];
  v_targets uuid[];
  v_skipped integer;
  v_notes integer;
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

  -- Orders anonymised before whose notes still carry this number (their names are already gone).
  select coalesce(array_agg(o.id order by o.number), '{}') into v_prior
    from app.orders o
   where o.store_id = p_store_id and o.customer_anonymized_at is not null
     and (concat_ws(' ', o.internal_note, o.closed_note, o.courier_note, o.payment_note)
            <> app.redact_contact_text(concat_ws(' ', o.internal_note, o.closed_note, o.courier_note, o.payment_note), null, array[v_phone])
          or exists (select 1 from app.order_status_events e where e.order_id = o.id and e.note is not null
                        and e.note <> app.redact_contact_text(e.note, null, array[v_phone])));
  v_targets := v_done || v_prior;

  -- Notes first, while the name and numbers are still on the order.
  perform set_config('aisellia.redact', 'on', true);
  update app.order_status_events e
     set note = app.redact_contact_text(e.note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone])
    from app.orders o
   where o.id = e.order_id and o.id = any (v_targets) and e.note is not null
     and e.note <> app.redact_contact_text(e.note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]);
  update app.audit_events a
     set before = app.redact_customer(app.redact_contact_json(a.before, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone])),
         after = app.redact_customer(app.redact_contact_json(a.after, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]))
    from app.orders o
   where a.store_id = p_store_id and a.entity_type = 'order' and a.entity_id = o.id and o.id = any (v_targets);
  perform set_config('aisellia.redact', 'off', true);

  update app.orders o
     set internal_note = app.redact_contact_text(o.internal_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
         closed_note = app.redact_contact_text(o.closed_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
         courier_note = app.redact_contact_text(o.courier_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
         payment_note = app.redact_contact_text(o.payment_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
         version = version + 1, updated_at = now()
   where o.id = any (v_targets)
     and row(o.internal_note, o.closed_note, o.courier_note, o.payment_note) is distinct from row(
           app.redact_contact_text(o.internal_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
           app.redact_contact_text(o.closed_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
           app.redact_contact_text(o.courier_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]),
           app.redact_contact_text(o.payment_note, o.customer_name, array[o.customer_phone, o.customer_phone2, v_phone]));
  get diagnostics v_notes = row_count;

  update app.orders set customer_name = null, customer_phone = null, customer_phone2 = null, area = null,
                        landmark = null, address_details = null, customer_note = null,
                        customer_anonymized_at = now(), version = version + 1, updated_at = now()
   where id = any (v_done);
  foreach v_id in array v_done loop
    perform app.order_recompute(v_id);   -- search fields no longer hold the name or phone
  end loop;

  -- Conversations that led to these orders hold the same contact data: their text goes too
  -- (metadata stays, so the order keeps its link).
  update app.messages m set body = null, body_purged_at = now()
    from app.conversations c
   where c.id = m.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done) and m.body is not null;
  update app.reply_suggestions s set text_rendered = null, facts_used = '[]', conflicts = '[]'
    from app.conversations c
   where c.id = s.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done);
  update app.ai_runs r set output_json = null, validation_errors = null, pii_map = null
    from app.conversations c
   where c.id = r.conversation_id and c.store_id = p_store_id and c.order_id = any (v_done);
  update app.conversations set customer_label = null where store_id = p_store_id and order_id = any (v_done);

  -- Stored answers of earlier requests repeat the contact data: they go too.
  delete from app.idempotency_keys
   where response -> 'data' ->> 'id' = any (array(select x::text from unnest(v_targets) x))
      or response -> 'data' ->> 'order_id' = any (array(select x::text from unnest(v_targets) x));

  perform app.audit(p_store_id, 'customer.anonymize', 'store', p_store_id, null,
                    jsonb_build_object('orders', cardinality(v_done), 'skipped_in_progress', v_skipped,
                                       'notes_redacted', v_notes));

  v_result := app.ok(jsonb_build_object('anonymized', cardinality(v_done), 'skipped_in_progress', v_skipped,
                                        'notes_redacted', v_notes, 'order_ids', to_jsonb(v_done)));
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

revoke all on function app.redact_contact_text(text, text, text[]), app.redact_contact_json(jsonb, text, text[]),
  app.protect_status_events()
from public, anon, authenticated, aisellia_ai, aisellia_ai_worker;
