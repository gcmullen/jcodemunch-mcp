#!/bin/bash
# Run audit_check.py on a single file and print a 1-line summary + violation lines.
set -u
F=$1
python3 validation/gold_annotations/tools/audit_check.py "$F" > /tmp/audit_out.json 2>&1
python3 - <<PY
import json
with open('/tmp/audit_out.json') as fh:
    d = json.load(fh)
print(f"clean={d['clean']} symbols={d['symbols']} callees={d['callees_total']} violations={len(d['violations'])}")
for v in d['violations']:
    print(" -", v)
PY
