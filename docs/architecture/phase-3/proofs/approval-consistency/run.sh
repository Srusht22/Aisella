#!/usr/bin/env bash
# DESIGN PROOF ONLY (Phase 3). Not a migration and not production code. Requires a disposable PostgreSQL 16+.
# Usage: PROOF_PSQL_ARGS="-h <host> -p <port> -U <superuser>" bash run.sh
# Throwaway proof runner. Exercises tenant isolation, privileges, idempotency, concurrency.
set -u
PSQL="psql ${PROOF_PSQL_ARGS:--h localhost -p 5432 -U postgres} -q -At -v ON_ERROR_STOP=0"
DIR=$(dirname "$0"); TMP=$(mktemp -d)
$PSQL -c "drop database if exists proof" -c "create database proof" >/dev/null
$PSQL -d proof -f "$DIR/schema.sql" >/dev/null
A=11111111-1111-1111-1111-111111111111; B=22222222-2222-2222-2222-222222222222
$PSQL -d proof <<SQL >/dev/null
insert into auth.users values ('$A', now()), ('$B', now());
insert into app.stores(id,name) values ('aaaaaaaa-0000-0000-0000-000000000001','Store A'),('bbbbbbbb-0000-0000-0000-000000000002','Store B');
insert into app.store_members values ('aaaaaaaa-0000-0000-0000-000000000001','$A','owner'),('bbbbbbbb-0000-0000-0000-000000000002','$B','owner');
insert into app.product_variants(id,store_id,label,price,stock_on_hand) values
 ('cccccccc-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','Beige Abaya M',35000,3);
insert into app.inventory_movements(store_id,variant_id,delta,resulting_qty,reason) values
 ('aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001',3,3,'initial_stock');
-- three pending orders of 2 units each competing for 3 units
insert into app.orders(id,store_id,status) values
 ('dddddddd-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','pending_approval'),
 ('dddddddd-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','pending_approval'),
 ('dddddddd-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','pending_approval');
insert into app.order_items(order_id,store_id,variant_id,quantity,quoted_unit_price)
 select o.id,o.store_id,'cccccccc-0000-0000-0000-000000000001',2,35000 from app.orders o;
SQL
as_user() { echo "set role authenticated; set request.jwt.claim.sub='$1'; set request.jwt.claim.role='authenticated'; $2"; }
as_service() { echo "set role service_role; set request.jwt.claim.role='service_role'; $1"; }
check() { printf '%-62s %s\n' "$1" "$2"; }

check "T1 B reads A's variants (RLS)" "rows=$($PSQL -d proof -c "$(as_user $B "select count(*) from app.product_variants;")")"
check "T2 A reads own variants" "rows=$($PSQL -d proof -c "$(as_user $A "select count(*) from app.product_variants;")")"
check "T3 A updates stock directly" "$($PSQL -d proof -c "$(as_user $A "update app.product_variants set stock_on_hand=99;")" 2>&1 | head -1)"
check "T4 B approves A's order" "$($PSQL -d proof -c "$(as_user $B "select api.approve_order('dddddddd-0000-0000-0000-000000000001',1,gen_random_uuid());")")"
check "T5 service_role (AI) approves" "$($PSQL -d proof -c "$(as_service "select api.approve_order('dddddddd-0000-0000-0000-000000000001',1,gen_random_uuid());")")"

# T6: same order approved concurrently from two sessions (different idempotency keys)
for i in 1 2; do $PSQL -d proof -c "$(as_user $A "select api.approve_order('dddddddd-0000-0000-0000-000000000001',1,gen_random_uuid());")" > "$TMP"/proof_t6_$i & done; wait
check "T6 concurrent approve same order (session 1)" "$(cat "$TMP"/proof_t6_1)"
check "T6 concurrent approve same order (session 2)" "$(cat "$TMP"/proof_t6_2)"
# T7: retry with the SAME idempotency key after success (lost-response scenario)
K=eeeeeeee-0000-0000-0000-000000000007
$PSQL -d proof -c "$(as_user $A "select api.approve_order('dddddddd-0000-0000-0000-000000000002',1,'$K');")" > "$TMP"/proof_t7a
check "T7 order 2 first attempt (1 unit left, needs 2)" "$(cat "$TMP"/proof_t7a)"
check "T8 stock after all attempts" "$($PSQL -d proof -c "select stock_on_hand from app.product_variants")"
check "T9 invariant stock = sum(movements)" "$($PSQL -d proof -c "select (select stock_on_hand from app.product_variants) = (select sum(delta) from app.inventory_movements)")"
check "T10 approved orders count" "$($PSQL -d proof -c "select count(*) from app.orders where status='approved'")"
# T11: replay of a successful approval with same key returns stored result, no new movement
$PSQL -d proof -c "update app.product_variants set stock_on_hand = stock_on_hand + 4; insert into app.inventory_movements(store_id,variant_id,delta,resulting_qty,reason) select store_id,id,4,stock_on_hand,'manual_adjustment' from app.product_variants" >/dev/null
K2=eeeeeeee-0000-0000-0000-000000000011
r1=$($PSQL -d proof -c "$(as_user $A "select api.approve_order('dddddddd-0000-0000-0000-000000000003',1,'$K2');")")
r2=$($PSQL -d proof -c "$(as_user $A "select api.approve_order('dddddddd-0000-0000-0000-000000000003',1,'$K2');")")
check "T11 first approval of order 3" "$r1"
check "T11 replay with same key" "$r2"
check "T11 movements for order 3" "$($PSQL -d proof -c "select count(*) from app.inventory_movements where order_id='dddddddd-0000-0000-0000-000000000003'")"
check "T12 invariant stock = sum(movements)" "$($PSQL -d proof -c "select (select stock_on_hand from app.product_variants) = (select sum(delta) from app.inventory_movements)")"
# T13: price changed after quote
$PSQL -d proof -c "insert into app.orders(id,store_id,status) values ('dddddddd-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000001','pending_approval'); insert into app.order_items(order_id,store_id,variant_id,quantity,quoted_unit_price) values ('dddddddd-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001',1,35000); update app.product_variants set price=38000;" >/dev/null
check "T13 approve after price change, no choice" "$($PSQL -d proof -c "$(as_user $A "select api.approve_order('dddddddd-0000-0000-0000-000000000004',1,gen_random_uuid());")")"
# T14: concurrency stress: 20 parallel approvals of distinct orders for 5 units
$PSQL -d proof -c "update app.product_variants set price=35000, stock_on_hand=stock_on_hand; insert into app.inventory_movements(store_id,variant_id,delta,resulting_qty,reason) select store_id,id,5-stock_on_hand,5,'count_correction' from app.product_variants; update app.product_variants set stock_on_hand=5;" >/dev/null
for n in $(seq 1 20); do id=$(printf 'ffffffff-0000-0000-0000-%012d' $n); $PSQL -d proof -c "insert into app.orders(id,store_id,status) values ('$id','aaaaaaaa-0000-0000-0000-000000000001','pending_approval'); insert into app.order_items(order_id,store_id,variant_id,quantity,quoted_unit_price) values ('$id','aaaaaaaa-0000-0000-0000-000000000001','cccccccc-0000-0000-0000-000000000001',1,35000);" >/dev/null; done
for n in $(seq 1 20); do id=$(printf 'ffffffff-0000-0000-0000-%012d' $n); $PSQL -d proof -c "$(as_user $A "select api.approve_order('$id',1,gen_random_uuid())->>'error';")" > "$TMP"/proof_t14_$n & done; wait
check "T14 20 parallel approvals for 5 units: approved" "$(cat "$TMP"/proof_t14_* | grep -c '^$')"
check "T14 rejected INSUFFICIENT_STOCK" "$(cat "$TMP"/proof_t14_* | grep -c INSUFFICIENT_STOCK)"
check "T14 final stock / invariant" "$($PSQL -d proof -c "select stock_on_hand, stock_on_hand=(select sum(delta) from app.inventory_movements) from app.product_variants")"
rm -rf "$TMP"
