#!/bin/sh
set -u
cd "$(dirname "$0")" || exit 1
fail=0
check() {
  name=$1; expected=$2; actual=$3
  if [ "$actual" = "$expected" ]; then
    printf 'OK    %-52s %s\n' "$name" "$actual"
  else
    printf 'FAIL  %-52s got=%s want=%s\n' "$name" "$actual" "$expected"
    fail=1
  fi
}
check "programs in repro.kernsight.prog" 68 \
  "$(grep -c '^executing program' repro/repro.kernsight.prog)"
trig=$(python3 - <<'PY'
import re
d = open('repro/repro.kernsight.prog', errors='replace').read()
p = re.split(r'(?m)^executing program (\d+):\n', d)[1:]
b = list(zip(p[0::2], p[1::2]))
print(','.join(n for n, t in b if 'uhid' in t.lower() and 'fail_nth: 5' in t))
PY
)
check "UHID trigger program indices" "64,67" "$trig"
check "GPF reports, 7.3 sequence replay" 1 \
  "$(grep -a -c 'general protection fault' logs/serial-7.3.log)"
check "GPF reports, 7.3 standalone run 1" 0 \
  "$(grep -a -c 'general protection fault' logs/serial-7.3-minimal1.log)"
check "GPF reports, 7.3 standalone run 2" 0 \
  "$(grep -a -c 'general protection fault' logs/serial-7.3-minimal2.log)"
check "GPF reports, 7.1.3 report" 1 \
  "$(grep -a -c 'general protection fault' logs/report-7.1.3.txt)"
first=$(grep -a -m1 'Oops: general protection fault' logs/serial-7.3.log |
  grep -oE '^\[ *[0-9]+\.[0-9]+' | tr -d '[] ')
case "$first" in
  276.2*) printf 'OK    %-52s %s\n' "first GPF timestamp (s), 7.3 sequence" "$first" ;;
  *) printf 'FAIL  %-52s got=%s want=276.2*\n' "first GPF timestamp (s), 7.3 sequence" "$first"; fail=1 ;;
esac
check "failslab injection logged in 7.3 sequence" yes \
  "$(grep -aq 'name failslab' logs/serial-7.3.log && echo yes || echo no)"
exit $fail
