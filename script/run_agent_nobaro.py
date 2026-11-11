"""Ablation: the reference agent without rank_anomalies (the BARO-style ranking tool).

The agent keeps describe_case, list_metrics, get_metric, search_logs, trace_summary,
call_graph and submit, so the LLM has to find the anomalies itself from raw telemetry.
Nothing in the RCAEval package is changed; the tool list and prompt are patched here.

    python script/run_agent_nobaro.py --tasks agent_tasks/re2-ob --model openai/gpt-x \
        --out results/preds_x_nobaro.jsonl --cases re2-ob-0004 ... --workers 4
"""
import argparse

from RCAEval.agent import prompt, react, toolkit

REMOVED = "rank_anomalies"

toolkit.TOOLS[:] = [t for t in toolkit.TOOLS if t["name"] != REMOVED]
toolkit.TOOL_NAMES[:] = [t["name"] for t in toolkit.TOOLS]
react.TOOL_SPECS[:] = [{"type": "function", "function": t} for t in toolkit.TOOLS]

prompt.SYSTEM_PROMPTS["nobaro"] = """You are an SRE investigating a failure in a microservice system. A fault was \
injected into one service at a known time; your job is to find the root cause.

You see the system only through the tools. Work like this:
1. Call describe_case to see the candidate services and which telemetry exists.
2. Find what changed after the inject time yourself: use list_metrics and get_metric to compare each \
service's metrics before and after the inject time, trace_summary to see latency and errors per \
service, and search_logs for new errors. No precomputed anomaly ranking is available.
3. Some series move in every incident whatever the fault, so one change alone is not proof. Pick your \
3 to 5 strongest suspect services and check each one's own evidence. Use call_graph to tell the \
service where a failure starts from the services that only feel its effects.
4. Call submit with 5 to 10 candidates ranked most likely first. Each candidate is a service from \
candidate_services or a <service>_<indicator> metric name such as cartservice_cpu; the indicator \
(cpu, mem, diskio, socket, latency, ...) says what kind of fault you believe it is, so name the \
metric that best shows the fault first.

Take the tool calls you need to be confident; your investigation ends when submit is accepted."""

p = argparse.ArgumentParser()
p.add_argument("--tasks", required=True)
p.add_argument("--model", required=True)
p.add_argument("--out", required=True)
p.add_argument("--cases", nargs="*")
p.add_argument("--max-steps", type=int, default=30)
p.add_argument("--max-cost-usd", type=float, default=2.0)
p.add_argument("--temperature", type=float, default=0.0)
p.add_argument("--workers", type=int, default=1)
p.add_argument("--toolkit-version", default=toolkit.TOOLKIT_VERSION, choices=toolkit.TOOLKIT_VERSIONS,
               help="recorded with the predictions; this arm has no rank_anomalies, so v1 and v2 behave alike")
args = p.parse_args()

assert REMOVED not in toolkit.TOOL_NAMES and len(react.TOOL_SPECS) == len(toolkit.TOOLS)
print("tools:", ", ".join(toolkit.TOOL_NAMES))
react.run_tasks(args.tasks, args.model, args.out, cases=args.cases, workers=args.workers,
                max_steps=args.max_steps, max_cost_usd=args.max_cost_usd,
                temperature=args.temperature, prompt_version="nobaro",
                toolkit_version=args.toolkit_version)
