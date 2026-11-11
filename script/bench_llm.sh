#!/usr/bin/env bash
# Chạy agent LLM tham chiếu trên RE2-OB rồi chấm điểm.
#   1. Điền MODEL và API key vào .env
#   2. bash script/bench_llm.sh                 # dùng cấu hình trong .env
#      MODEL=openai/gpt-4o bash script/bench_llm.sh   # ghi đè tạm một biến
#      ARM=nobaro TOOLKIT_VERSION=2 REP=2 SUBSET=all90 bash script/bench_llm.sh
#   ARM: baro (agent có rank_anomalies) | nobaro (bỏ rank_anomalies, script/run_agent_nobaro.py)
#   TOOLKIT_VERSION: hành vi tool, xem FINDINGS.md (mặc định 2). REP: nhãn lần lặp (r1, r2, ...)
#   File kết quả: results/*_<model>_<arm>_tk<version>_<subset>_r<rep>.*
# Chạy lại cùng lệnh sẽ bỏ qua các case đã xong (file dự đoán được nối thêm).
set -euo pipefail
cd "$(dirname "$0")/.."

# Nạp .env nhưng giữ biến đã đặt sẵn trên dòng lệnh
if [[ -f .env ]]; then
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    val="${val%%#*}"; val="$(echo "$val" | xargs)"
    [[ -z "${!key:-}" && -n "$val" ]] && export "$key=$val"
  done < .env
fi

: "${MODEL:?Chưa đặt MODEL trong .env}"
SUBSET="${SUBSET:-pilot30}"
WORKERS="${WORKERS:-4}"; MAX_STEPS="${MAX_STEPS:-30}"
MAX_COST_USD="${MAX_COST_USD:-2.0}"; TEMPERATURE="${TEMPERATURE:-0.0}"
ARM="${ARM:-baro}"; TOOLKIT_VERSION="${TOOLKIT_VERSION:-2}"; REP="${REP:-1}"
[[ -n "${OPENAI_API_BASE:-}" ]] && export OPENAI_BASE_URL="$OPENAI_API_BASE"

BIN=.venv/bin/rcaeval-agent
TASKS=agent_tasks/re2-ob
[[ -d "$TASKS" ]] || "$BIN" export --dataset re2-ob --out agent_tasks

case "$SUBSET" in
  pilot30) CASES=(--cases $(cat agent_tasks/re2-ob.pilot30.txt))
           EVAL=(--answers agent_tasks/re2-ob.pilot30.answers.jsonl) ;;
  all90)   CASES=(); EVAL=(--tasks "$TASKS") ;;
  *) echo "SUBSET phải là pilot30 hoặc all90" >&2; exit 1 ;;
esac

SLUG="$(echo "$MODEL" | tr '/:' '__')_${ARM}_tk${TOOLKIT_VERSION}_${SUBSET}_r${REP}"
mkdir -p results
PREDS="results/preds_${SLUG}.jsonl"

case "$ARM" in
  baro)   RUN=("$BIN" run) ;;
  nobaro) RUN=(.venv/bin/python script/run_agent_nobaro.py) ;;
  *) echo "ARM phải là baro hoặc nobaro" >&2; exit 1 ;;
esac

echo ">>> Model: $MODEL | Arm: $ARM | Toolkit: v$TOOLKIT_VERSION | Subset: $SUBSET | Rep: $REP | Output: $PREDS"
"${RUN[@]}" --tasks "$TASKS" --model "$MODEL" --out "$PREDS" "${CASES[@]}" \
  --max-steps "$MAX_STEPS" --max-cost-usd "$MAX_COST_USD" \
  --temperature "$TEMPERATURE" --workers "$WORKERS" --toolkit-version "$TOOLKIT_VERSION"

echo ">>> Chấm điểm"
"$BIN" evaluate "${EVAL[@]}" --predictions "$PREDS" --report-chance \
  --per-case-out "results/percase_${SLUG}.jsonl" --json-out "results/summary_${SLUG}.json" \
  | tee "results/report_${SLUG}.txt"

echo ">>> So với BARO: results/summary_baro_${SUBSET}.json"
