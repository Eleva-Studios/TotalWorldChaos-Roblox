# usage_cost.py: sums the API usage in this chat's transcripts (main + subagents), deduplicated by message id, and prices it
# at Opus 5.5's API rates: $4/MTok input, $20 output, $0.20 cache read, cache writes 1.25x (5 min) or 2x (1 hour).
# Usage: python3 -I tools/checks/usage_cost.py ~/.claude/projects/<project>/<session-id>.jsonl
# (the session's subagent transcripts in the <session-id>/ folder next to it are counted too).
import json, glob, os, sys, collections
main_file = sys.argv[1]
files = [main_file] + sorted(glob.glob(main_file[: -len(".jsonl")] + "/**/*.jsonl", recursive=True))
msgs = {}  # id -> (group, day, model, usage)
for f in files:
    group = "main" if f == main_file else "subagents"
    with open(f, errors="replace") as fh:
        for line in fh:
            if '"usage"' not in line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            m = d.get("message") or {}
            u = m.get("usage")
            if d.get("type") != "assistant" or not u:
                continue
            mid = m.get("id") or d.get("requestId") or d.get("uuid")
            day = (d.get("timestamp") or "")[:10]
            prev = msgs.get(mid)
            if prev is None or (u.get("output_tokens") or 0) >= (prev[3].get("output_tokens") or 0):
                msgs[mid] = (group, prev[1] if prev else day, m.get("model", "?"), u)
def price(u):
    cc = u.get("cache_creation") or {}
    w5, w1 = cc.get("ephemeral_5m_input_tokens"), cc.get("ephemeral_1h_input_tokens")
    cw = u.get("cache_creation_input_tokens") or 0
    if w5 is None and w1 is None:
        w5, w1 = 0, cw  # no breakdown: assume the 1-hour TTL this session uses
    return {
        "input": (u.get("input_tokens") or 0) * 4 / 1e6,
        "cache write": ((w5 or 0) * 5 + (w1 or 0) * 8) / 1e6,
        "cache read": (u.get("cache_read_input_tokens") or 0) * 0.20 / 1e6,
        "output": (u.get("output_tokens") or 0) * 20 / 1e6,
    }, {"input": u.get("input_tokens") or 0, "cache write": cw, "cache read": u.get("cache_read_input_tokens") or 0, "output": u.get("output_tokens") or 0}
tot = collections.defaultdict(lambda: collections.defaultdict(float))
toks = collections.defaultdict(lambda: collections.defaultdict(float))
models = collections.Counter()
for mid, (g, day, model, u) in msgs.items():
    c, t = price(u)
    models[model] += 1
    for k in c:
        for key in (g, "day " + day, "ALL"):
            tot[key][k] += c[k]; toks[key][k] += t[k]
    tot[g]["calls"] += 1; tot["ALL"]["calls"] += 1; tot["day " + day]["calls"] += 1
print("files", len(files), "| API calls", len(msgs), "| models", dict(models))
for key in sorted(tot, key=lambda k: (k != "ALL", k)):
    c = tot[key]; s = sum(v for k, v in c.items() if k != "calls")
    print(f"{key:15s} ${s:9.2f}  calls {int(c['calls']):6d}  " + "  ".join(f"{k} ${c[k]:.2f} ({toks[key][k]/1e6:.1f}M)" for k in ("input", "cache write", "cache read", "output")))
