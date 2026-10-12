#!/usr/bin/env bash
set -euo pipefail

PORTS=(1881 1882)
ENDPOINT="/trip/event"
DUP="${DUP:-20}"
KILL="${KILL:-0}"
TIMEOUT="${TIMEOUT:-240}"
RUN="$(date +%s)"

rc() { docker compose exec -T redis redis-cli "$@" | tr -d '\r'; }

group_field() {   # значення поля з XINFO GROUPS (pending, lag, ...)
  rc --raw XINFO GROUPS trips:events | awk -v k="$1" 'prev==k {print; exit} {prev=$0}'
}

send() {          # send <port> <body> -> http-код
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "http://localhost:$1${ENDPOINT}" \
    -H 'Content-Type: application/json' -d "$2"
}

blast() {         # blast <body> <copies>: паралельно, порти по черзі
  local body="$1" n="$2" i
  for i in $(seq 1 "$n"); do
    send "${PORTS[$((i % 2))]}" "$body" &
  done
  wait
}

echo "==> Піднімаю стенд"
docker compose up -d --build

echo "==> Чекаю, поки обидва Node-RED відповідатимуть"
for p in "${PORTS[@]}"; do
  until curl -s -o /dev/null "http://localhost:$p/"; do sleep 1; done
  echo "    :$p ok"
done

echo "==> Скидаю стан Redis і створюю consumer group"
rc DEL trips:events trips:dead >/dev/null
rc XGROUP CREATE trips:events workers 0 MKSTREAM >/dev/null 2>&1 || true
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "==> A: ${DUP} ідентичних запитів паралельно (очікую 1 запис у стрімі)"
BODY_A="{\"trip_id\":\"T-${RUN}-A\",\"status\":\"started\",\"sequence\":1}"
blast "$BODY_A" "$DUP" | sort | uniq -c | sed 's/^/    http /'

echo "==> B: 3 різні статуси однієї поїздки, кожен по 5 копій (очікую 3 записи)"
for s in started arrived finished; do
  blast "{\"trip_id\":\"T-${RUN}-B\",\"status\":\"$s\"}" 5 | sort | uniq -c | sed "s/^/    $s: http /"
done

EXPECTED=4
echo "==> У стрімі зараз: $(rc XLEN trips:events) (очікую $EXPECTED)"

if [ "$KILL" = "1" ]; then
  sleep 3
  echo "==> KILL=1: вбиваю node-red-2 посеред обробки"
  docker compose kill node-red-2 >/dev/null
fi

echo "==> Чекаю, поки черга й pending спорожніють (до ${TIMEOUT} с)"
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  pending="$(group_field pending)"; lag="$(group_field lag)"
  echo "    pending=${pending:-?} lag=${lag:-0}"
  if [ "${pending:-1}" = "0" ] && [ "${lag:-0}" = "0" ]; then break; fi
  if [ "$(date +%s)" -gt "$deadline" ]; then echo "    таймаут"; break; fi
  sleep 5
done

[ "$KILL" = "1" ] && docker compose start node-red-2 >/dev/null

echo
echo "==================== РЕЗУЛЬТАТ ===================="
entries="$(rc XLEN trips:events)"
dead="$(rc XLEN trips:dead)"
processed="$(docker compose logs --no-log-prefix --since "$START" node-red-1 node-red-2 2>/dev/null \
  | grep -o 'processed [0-9]*-[0-9]*' | sort | uniq -c || true)"
distinct="$(printf '%s\n' "$processed" | grep -c . || true)"
maxdup="$(printf '%s\n' "$processed" | awk 'NF{print $1}' | sort -rn | head -1)"
failures="$(docker compose logs --no-log-prefix --since "$START" node-red-1 node-red-2 2>/dev/null \
  | grep -c 'random failure' || true)"

echo "Записів у стрімі:             $entries  (очікую $EXPECTED)"
echo "Унікальних оброблених подій:  $distinct  (очікую $EXPECTED)"
echo "Макс. обробок однієї події:   ${maxdup:-0}  (очікую 1)"
echo "Випадкових збоїв (ретраї):    $failures"
echo "У dead-letter:                $dead"
echo "Лишилось у pending:           $(group_field pending)"
echo
echo "Хто що обробив:"
docker compose logs --no-log-prefix --since "$START" node-red-1 node-red-2 2>/dev/null | grep 'processed' | sed 's/^/    /' || true

if [ "$entries" = "$EXPECTED" ] && [ "$distinct" = "$EXPECTED" ] && [ "${maxdup:-0}" = "1" ] \
   && [ "$(group_field pending)" = "0" ]; then
  echo; echo "PASS: дублі відсічено, кожна подія оброблена рівно один раз, нічого не загублено"
else
  echo; echo "FAIL або неповний прогін: перегляньте цифри вище"
  exit 1
fi
