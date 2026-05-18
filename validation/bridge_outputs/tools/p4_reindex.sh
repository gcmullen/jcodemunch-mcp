#!/usr/bin/env bash
# Phase 5.3 — full wipe + reindex of all 39 p4-validation corpora.
# Per spike §7 step 6: "reindex = wipe + rebuild" (user feedback 2026-05-17).
# Picks up post-5.2a bridge behavior (DSL walker + dedup fix + G9 + G14 + tkwait).

set -u

export CODE_INDEX_PATH=/home/giles/.code-index/p4-validation
JCM=/home/giles/git/jcodemunch-mcp-fork/.venv/bin/jcodemunch-mcp
LOG=/tmp/p4_reindex_5_3.log

# 39 source paths derived from existing local-*.db meta.source_root values.
SOURCES=(
    /home/giles/git/tcl-corpus/BWidget
    /home/giles/bluice/BluIceWidgets
    /home/giles/bluice/DcsWidgets
    /home/giles/bluice/auth
    /home/giles/bluice/auth_client
    /home/giles/bluice/autochooch
    /home/giles/bluice/bl831-dhs-tcl
    /home/giles/bluice/cbflib
    /home/giles/bluice/cbflib-upstream
    /home/giles/git/tcl-corpus/tcllib/clay
    /home/giles/git/tcl-corpus/tcllib/cmdline
    /home/giles/git/tcl-corpus/tcllib/cron
    /home/giles/bluice/dali
    /home/giles/bluice/dcs-lib-tcl
    /home/giles/bluice/dcs_tcl_packages
    /home/giles/bluice/dcsconfig
    /home/giles/bluice/dcsmsg
    /home/giles/bluice/dcss
    /home/giles/git/tcl-corpus/tcllib/defer
    /home/giles/bluice/dhs
    /home/giles/bluice/dhs-tcl
    /home/giles/bluice/di-tcl
    /home/giles/bluice/diffimage
    /home/giles/git/git-gui
    /home/giles/bluice/http_cpp
    /home/giles/bluice/imgsrv
    /home/giles/bluice/impdhs
    /home/giles/bluice/imperson_cpp
    /home/giles/bluice/java_dcss_sim
    /home/giles/bluice/jpegsoc
    /home/giles/bluice/logging
    /home/giles/bluice/newmat10
    /home/giles/bluice/simdetector
    /home/giles/bluice/simdhs
    /home/giles/git/tcl-corpus/tcllib/snit
    /tmp/tcl_canary
    /home/giles/bluice/tcl_clibs
    /home/giles/bluice/xos
    /home/giles/bluice/xos_cpp
)

echo "=== Phase 5.3 reindex starting at $(date) ===" | tee "$LOG"
echo "Total corpora: ${#SOURCES[@]}" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Step 1: wipe local-* DBs + dirs (keep config.jsonc).
echo "--- Wiping p4-validation local-* state ---" | tee -a "$LOG"
rm -f  "$CODE_INDEX_PATH"/local-*.db
rm -rf "$CODE_INDEX_PATH"/local-*
echo "wiped: $(ls "$CODE_INDEX_PATH"/local-* 2>&1 | wc -l) entries remaining (should be 0)" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Step 2: reindex each corpus, log per-corpus result.
ok=0
errs=0
i=0
for src in "${SOURCES[@]}"; do
    i=$((i+1))
    name=$(basename "$src")
    echo "[$i/${#SOURCES[@]}] indexing $name ($src)" | tee -a "$LOG"
    if [ ! -d "$src" ]; then
        echo "  SKIP: source missing" | tee -a "$LOG"
        errs=$((errs+1))
        continue
    fi
    if "$JCM" index --no-ai-summaries --log-level WARNING "$src" >>"$LOG" 2>&1; then
        ok=$((ok+1))
    else
        errs=$((errs+1))
        echo "  FAILED" | tee -a "$LOG"
    fi
done

echo "" | tee -a "$LOG"
echo "=== Phase 5.3 reindex complete at $(date) ===" | tee -a "$LOG"
echo "  ok:     $ok" | tee -a "$LOG"
echo "  errors: $errs" | tee -a "$LOG"
echo "  total:  ${#SOURCES[@]}" | tee -a "$LOG"
