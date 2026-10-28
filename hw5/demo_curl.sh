#!/bin/bash
# demo_curl.sh - step 4: one successful and two erroneous curl requests,
# showing both tables before and after each request.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IP=$(gcloud --project=cedar-pottery-508921-u1 compute addresses describe hw5-web-ip \
     --region=us-central1 --format='value(address)')
Q="$HERE/.venv/bin/python $HERE/dbq.py --tables"
step() { echo; echo "################ $*"; }
step "BEFORE any request";                    $Q
step "REQUEST 1 (success): GET /123.html"
curl -s -o /dev/null -w "HTTP %{http_code}\n" -H "X-country: France" -H "X-client-IP: 203.0.113.7" \
  -H "X-gender: Female" -H "X-age: 26-35" -H "X-income: 60k-100k" -H "X-time: 2026-10-28 14:00:00" \
  "http://$IP/123.html"
step "AFTER request 1";                       $Q
step "REQUEST 2 (error 404): GET /99999.html"
curl -s -w "HTTP %{http_code}\n" -H "X-country: Canada" -H "X-gender: Male" -H "X-age: 17-25" \
  -H "X-income: 20k-40k" -H "X-time: 2026-10-28 09:00:00" "http://$IP/99999.html"
step "AFTER request 2";                       $Q
step "REQUEST 3 (error 501): PUT /123.html"
curl -s -w "HTTP %{http_code}\n" -X PUT -H "X-country: Japan" "http://$IP/123.html"
step "AFTER request 3";                       $Q
