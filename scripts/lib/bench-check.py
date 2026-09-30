#!/usr/bin/env python3
"""bench-check.py — the check-mode half of scripts/check-bench.sh, extracted so
the confirm pass can re-run the *same* comparison instead of a second copy of it.

usage: bench-check.py THRESHOLD RESULTS BASELINE LOG [--only n1,n2] [--breach-out path]

  --only n1,n2      confirm-pass mode: evaluate only these metrics. The alloc
                    criterion, the ci-refresh merge and the baseline-hygiene
                    WARNs are all skipped — they belong to the primary verdict,
                    and an alloc breach never reaches a confirm pass (it is a
                    count, final on first measurement).
  --breach-out path write {"slower": [...], "alloc_breach": [...]} before the
                    exit, so the caller can tell a duration-only failure (a
                    candidate for one confirm re-run) from anything else.

Exit code: 1 when a compared metric is slower than THRESHOLD x its baseline or
an alloc budget is exceeded, else 0. Inputs beyond argv come from the
environment exactly as scripts/check-bench.sh sets them (BENCH_REF_METRIC,
BENCH_REF_METRICS, BENCH_NORMALIZED_METRICS, BENCH_MACHINE, and for the primary
mode BENCH_UPDATE_MISSING_OUT / GITHUB_RUN_ID).
"""

import json, os, re, sys

threshold = float(sys.argv[1])
results_path, base_path, log_path = sys.argv[2], sys.argv[3], sys.argv[4]
only = None
breach_out = None
_rest = sys.argv[5:]
_i = 0
while _i < len(_rest):
    if _rest[_i] == "--only" and _i + 1 < len(_rest):
        only = {n for n in _rest[_i + 1].split(",") if n}
        _i += 2
    elif _rest[_i] == "--breach-out" and _i + 1 < len(_rest):
        breach_out = _rest[_i + 1]
        _i += 2
    else:
        _i += 1
ref_default = os.environ["BENCH_REF_METRIC"]
machine = os.environ.get("BENCH_MACHINE", "")

# The gating list, as `metric -> reference`: `metric=reference` names its own, a
# bare `metric` takes the default. The dict keeps the list's order.
normalized = {}
for item in os.environ["BENCH_NORMALIZED_METRICS"].split(";"):
    if not item:
        continue
    metric, sep, ref = item.partition("=")
    normalized[metric] = ref if sep else ref_default

# Every metric named as a reference — the declared ones (the default divisor plus
# any candidate nothing divides by yet), and any the list names: those are host
# measurements, never framework metrics.
ref_names = {n for n in os.environ["BENCH_REF_METRICS"].split(";") if n} | set(normalized.values())

if not os.path.exists(base_path):
    print(f"FAIL: no baseline at {base_path} — create one with: scripts/check-bench.sh --update", file=sys.stderr)
    sys.exit(2)

cur = json.load(open(results_path))
base_arr = json.load(open(base_path))
base = {m["name"]: m for m in base_arr}
seen = set()

# The reference values for this run: every normalized metric is divided by the
# median this same run measured *of its own reference*, which is what cancels the
# host generation.
values = {m["name"]: m["value"] for m in cur}


def reference_for(metric):
    """(name, value) of the reference `metric` is divided by; value None when this
    run has no usable one."""
    name = normalized[metric]
    value = values.get(name)
    if value is None or value <= 0:
        return name, None
    return name, value


# The suite's `[med3] <name>: min / median / max` lines, so a breach can show the
# three samples behind the median it compared, and its `[alloc]` rows — the
# second criterion (see the header). Missing log (deleted temp dir, piped run)
# degrades to no sample lines and no alloc readings, never to a crash.
samples = {}
alloc_meas = {}
ALLOC_LINE = re.compile(r"^\s*\[alloc\] (.+): ([0-9]+(?:\.[0-9]+)?) alloc/op")
if os.path.exists(log_path):
    with open(log_path, errors="replace") as fh:
        for line in fh:
            entry = line.strip()
            if entry.startswith("[med3] "):
                head, _, rest = entry[len("[med3] "):].partition(": ")
                if rest:
                    samples[head] = rest
                continue
            hit = ALLOC_LINE.match(entry)
            if hit:
                # Metric names contain no colon, so the first colon is the
                # name/value separator; the note after `alloc/op` is ignored.
                alloc_meas[hit.group(1)] = float(hit.group(2))

slower, unmeasurable, pending, mismatch, host_notes, retargeted = [], [], [], [], [], []
ratio_detail = []
new_metrics = [m["name"] for m in cur if m["name"] not in base]

# ── the declared references, this run vs their recorded values ──
# Every host reference is a *host* measurement, so the drift here is the context
# the verdict below is read in, and it is printed on every run (pass or fail)
# rather than only when it breaches: the failure this block exists for reported
# the reference 1.61x away, which is inside THRESHOLD and therefore never
# reached the gate's own host note (see the header). `moved` is that reading, and
# the FAIL block below points at it. Role labels and their reasons come from
# `REF_METRIC_ROLES`, which decides nothing (presentation only).
suspect = float(os.environ.get("BENCH_HOST_SUSPECT", "1.25"))
roles = {}
for item in os.environ.get("BENCH_REF_ROLES", "").split(";"):
    if not item:
        continue
    role_name, _, rest = item.partition("=")
    role, _, reason = rest.partition("|")
    roles[role_name] = (role, reason)
role_label = {"control": "control reference", "candidate": "candidate reference",
              "hand-off": "hand-off pair", "reference": "reference"}
# Only these roles are a reading about the *machine*. The hand-off pair is not:
# it swings 1.84x / 3.09x within one machine by construction (thread hand-off),
# so calling its drift "the host moved" would be the wrong answer — it is that
# pair's own noise, and its rows are tagged `MOVED` rather than `HOST-MOVED`.
host_roles = ("control", "candidate", "reference")
declared = [n for n in os.environ.get("BENCH_REF_METRICS", "").split(";") if n]
for ref_name in normalized.values():
    if ref_name not in declared:
        declared.append(ref_name)
reference_rows = []
moved = []
for ref_name in declared:
    actual = values.get(ref_name)
    entry = base.get(ref_name)
    was = None if entry is None else entry.get("value")
    factor = None if not was or actual is None else actual / was
    users = [n for n in normalized if normalized[n] == ref_name]
    divides = f"{len(users)} metric(s) divide by it" if users else "no metric divides by it yet"
    role, _reason = roles.get(ref_name, ("reference", ""))
    out_of_band = factor is not None and (factor > suspect or factor < 1.0 / suspect)
    host_moved = out_of_band and role in host_roles
    if factor is None:
        tag = "n/a"
    elif host_moved:
        tag = "HOST-MOVED"
    elif out_of_band:
        tag = "MOVED"
    else:
        tag = "flat"
    if actual is None:
        detail = "not measured in this run"
    elif was is None:
        detail = f"{actual:>9.3f} ms (no recorded value to compare)"
    else:
        detail = f"{was:>8.3f} → {actual:>9.3f} ms  {factor:.2f}x"
    reference_rows.append((ref_name, detail, tag, role_label.get(role, role), divides, role, factor))
    if host_moved:
        moved.append((ref_name, was, actual, factor))
for m in cur:
    name, actual = m["name"], m["value"]
    if only is not None and name not in only:
        continue
    seen.add(name)
    if name not in base:
        continue
    entry = base[name]
    was = entry.get("value")
    # Which criterion applies is decided by the gate's list and cross-checked
    # against what the recording actually stored: comparing a ratio to
    # milliseconds (0.77 vs 16.9) or milliseconds to a ratio passes everything,
    # so a disagreement is reported instead of compared.
    baseline_is_ratio = entry.get("normalized_by") is not None
    gate_is_ratio = name in normalized
    if baseline_is_ratio != gate_is_ratio:
        mismatch.append(f"{name} — baseline holds "
                         f"{'a ratio (normalized_by=' + str(entry.get('normalized_by')) + ')' if baseline_is_ratio else 'absolute milliseconds'}"
                         f", the gating list says {'ratio' if gate_is_ratio else 'absolute milliseconds'}")
        continue

    # Two ratios recorded against different denominators are different units, and
    # comparing them would pass (or fail) on arithmetic that means nothing. The
    # check for that lives inside the ratio branch below, after the reference
    # lookup: a *missing* reference is the more specific diagnosis (a name this run
    # did not measure at all) and has to be said first, so that nobody reads
    # "--update" as the fix for a reference name that does not exist.
    if name in ref_names:
        # A reference is the host, not the framework. Gating it on an absolute
        # value would fire on exactly the host generation change this criterion
        # exists to cancel, so it is reported and stays out of the verdict (see
        # the header): a breach here says "this runner is a different generation",
        # which is the context for everything above it, not a regression.
        users = [n for n in normalized if normalized[n] == name]
        divides = (f"{len(users)} normalized metric(s) divide by it" if users
                   else "no metric in the list divides by it yet (candidate reference)")
        if was is None:
            pending.append(f"{name} (absolute ms — reported, never gated)")
        elif was > 0 and (actual > was * threshold or actual < was / threshold):
            host_notes.append(f"{name}: baseline {was:.3f} ms → actual {actual:.3f} ms ({actual / was:.2f}x) — this is the host's memory path, not a framework metric; {divides}, and it is reported rather than gated")
        continue

    if gate_is_ratio:
        ref_name, ref = reference_for(name)
        if ref is None:
            unmeasurable.append(f"{name} (no '{ref_name}' in this run to divide by)")
            continue
        if entry.get("normalized_by") != ref_name:
            # The recording says which reference it divided by, so a later change of
            # reference is visible: reported and skipped, not compared. Re-record it
            # with `--update` on this machine class after changing the list.
            retargeted.append(f"{name} — baseline is a ratio to '{entry.get('normalized_by')}', the gating list says '{ref_name}'")
            continue
        if was is None:
            pending.append(f"{name} (ratio to '{ref_name}')")
            continue
        ratio = actual / ref
        ratio_detail.append((name, ratio, was, actual, ref_name, ref))
        if ratio > was * threshold:
            slower.append((name, "ratio",
                           f"baseline ratio {was:.4f} → actual {ratio:.4f} "
                           f"(= {actual:.3f} ms ÷ '{ref_name}' {ref:.3f} ms)",
                           ratio / was - 1))
        continue

    # A baseline of exactly 0.000 (a benchmark the optimizer folded away) has no
    # ratio to compare against; say so instead of dividing by zero.
    if was is None:
        pending.append(f"{name} (absolute ms)")
    elif was <= 0:
        unmeasurable.append(f"{name} (baseline 0.000)")
    elif actual > was * threshold:
        slower.append((name, "absolute", f"baseline {was:.3f} ms → actual {actual:.3f} ms", actual / was - 1))

gone = [n for n in base if n not in seen]
gated_ratio = [m["name"] for m in cur if m["name"] in normalized]

# ── the second criterion: allocations per op ──
# A budget is optional per entry; a count is exact (no median, no host wobble),
# so an alloc breach fails the run outright and the host check below — which
# exists to excuse a *duration* — is never consulted for it.
alloc_breach = []
alloc_unmeasured = []
for name, entry in (base.items() if only is None else []):
    budget = entry.get("max_alloc_per_op")
    if budget is None:
        continue
    measured = alloc_meas.get(name)
    if measured is None:
        alloc_unmeasured.append(name)
        continue
    if measured > budget:
        alloc_breach.append((name, budget, measured))
budgeted = sum(1 for e in base.values() if e.get("max_alloc_per_op") is not None)

# ── the CI-refresh artifact (BENCH_UPDATE_MISSING_OUT) ──
# The gate run already measured everything, so a green run on a runner can ride
# along as a merged candidate baseline for a maintainer to review and commit
# (ci.yml uploads it; see the header). Existing entries are kept **verbatim** —
# notes and max_alloc_per_op included, nothing already recorded is rewritten —
# so this path can never loosen the ratchet the way a blanket --update would.
# Only entries the baseline does not know yet, and ratios still pending a value,
# are filled from this run. Written before the verdict below on purpose: the
# upload step runs only on green jobs anyway, and locally the file is a
# convenience for the same review.
merge_out = os.environ.get("BENCH_UPDATE_MISSING_OUT")
if merge_out and only is None:
    run_id = os.environ.get("GITHUB_RUN_ID")
    prov = f"recorded from run {run_id} ({machine})" if run_id else None
    cur_by_name = {m["name"]: m for m in cur}
    merged, added_now, filled = [], [], []
    for entry in base_arr:
        name = entry["name"]
        m = cur_by_name.get(name)
        # A ratio entry this machine class has not recorded a value for yet:
        # fill it from this run when the run supplies a usable reference of the
        # recorded name (the gate's pending WARN above names the same fix).
        if (m is not None and entry.get("normalized_by") is not None
                and entry.get("value") is None and name in normalized
                and normalized[name] == entry["normalized_by"]):
            _ref_name, ref = reference_for(name)
            if ref is not None:
                e = dict(entry)
                e["value"] = round(m["value"] / ref, 4)
                if prov:
                    e["note"] = prov
                merged.append(e)
                filled.append(name)
                continue
        merged.append(entry)
    for m in cur:
        name = m["name"]
        if name in base:
            continue
        if name in normalized:
            # The gate list gates it as a ratio: record a ratio, or leave the
            # entry pending when this run produced no usable reference.
            ref_name, ref = reference_for(name)
            e = {"name": name, "unit": "ratio",
                 "value": (round(m["value"] / ref, 4) if ref is not None else None),
                 "normalized_by": ref_name}
        else:
            e = {"name": name, "unit": m.get("unit", "ms"), "value": m["value"]}
        if prov:
            e["note"] = prov
        merged.append(e)
        added_now.append(name)
    with open(merge_out, "w") as fh:
        json.dump(merged, fh, indent=2)
        fh.write("\n")
    print(f"ci-refresh artifact: {merge_out} <- {len(merged)} entry/ies "
          f"({len(added_now)} added, {len(filled)} pending filled)"
          + (f": {', '.join(added_now + filled)}" if added_now or filled else " — nothing new"))

print(f"machine:  {machine}")
print(f"criterion: {len(cur) - len(gated_ratio)} metric(s) absolute (median ms) + {len(gated_ratio)} normalized (each metric ÷ its own reference, both medians of this run), threshold {threshold}x on both; {budgeted} baseline entry/entries carry a max_alloc_per_op budget, judged on this run's [alloc] rows")

print("references — recorded and printed, never gated on duration; a baseline budget on one is")
print("  still judged on its [alloc] row, because a count is host-independent, unlike these numbers:")
print("  a reading on one of these is a candidate")
print("  fallback (re-run before changing anything), not something to ignore:")
for ref_name, detail, tag, role, divides, _key, _factor in reference_rows:
    print(f"  RE-RUN-BEFORE-FIX  {ref_name:<28s} {detail:<34s} {tag:<10s} ({role}; {divides})")
host_readable = [r for r in reference_rows
                 if r[2] != "n/a" and r[5] in ("control", "candidate", "reference")]
handoff_moved = [r for r in reference_rows if r[2] == "MOVED"]
print(f"  {len(moved)} of {len(host_readable)} host reference(s) outside the {suspect:.2f}x host-suspect band"
      + ("" if moved else " — the host did not move in this run"))
if handoff_moved:
    print(f"  {len(handoff_moved)} hand-off row(s) MOVED — that pair swings 1.84x/3.09x within one machine by")
    print("  construction, so its drift says nothing about the host (docs/RUNTIME.md §12.5).")
print("  role tags: control reference = the host's own atomic cost (gating it fires on a host-generation")
print("  change); candidate reference = recorded for a reference change no single machine can settle;")
print("  hand-off pair = judged against each other (docs/RUNTIME.md §12.5), not against a gate.")
print("  'noise or regression?' — bash scripts/check-bench.sh --explain <this log>; the convention is")
print("  docs/dev/READING_NUMBERS.md.")

if ratio_detail:
    print("normalized — the two ratios the gate compares (metric ÷ its reference, same run):")
    for name, ratio, was, actual, ref_name, ref in ratio_detail:
        compared = f"baseline ratio {was:.4f}, {ratio / was:.2f}x" if was is not None else "no baseline ratio to compare"
        print(f"  {name:<28s} {actual:>9.3f} ms / {ref_name} {ref:>8.3f} ms = {ratio:.4f}  ({compared})")

if slower:
    print(f"FAIL: {len(slower)} metric(s) slower than the baseline by more than {threshold}x (lower is better):")
    for name, kind, detail, pct in slower:
        print(f"  [{kind:8s}] {name}: {detail} (+{pct * 100:.1f}%)")
        if name in samples:
            print(f"      samples: {samples[name]}")
    print("  [absolute] compares milliseconds; [ratio] compares the metric divided by")
    print("  this run's own reference against the ratio the baseline recorded, so the host")
    print("  cancels out but extra work in the metric does not (an added allocation, lock")
    print("  or atomic raises the ratio). Both compared values are medians of 3; three")
    print("  slow samples are a regression, one outlier sample (see `samples:` above) is")
    print("  machine noise — re-run before fixing.")
    # The host check: the references in this run are printed above with their
    # drift, and that is the reading that tells a slow host from slow code —
    # which is what the recorded false red needed and did not have. Only *host*
    # roles count here (see `host_roles`): a hand-off row's drift is that pair's
    # own spread, so it must not be read as "the host moved".
    measured_refs = [r for r in reference_rows
                     if r[2] != "n/a" and r[5] in ("control", "candidate", "reference")]
    if moved:
        print(f"  host check: {len(moved)} of {len(measured_refs)} host reference(s) are outside the {suspect:.2f}x band in this run:")
        for ref_name, was, actual, factor in moved:
            print(f"      {ref_name}: {was:.3f} → {actual:.3f} ms ({factor:.2f}x)")
        print("      RE-RUN-BEFORE-FIX: a host reference moved with the metric, so this failure is not yet")
        print("      evidence about the code. Re-run on a quiet machine and compare (--explain).")
    elif measured_refs:
        worst = max(measured_refs, key=lambda r: max(r[6], 1.0 / r[6]) if r[6] else 1.0)
        print(f"  host check: every measured host reference is inside the {suspect:.2f}x band (worst: {worst[0]} {worst[6]:.2f}x)")
        print(f"      — the host did not move, so this is a real-regression candidate at the {threshold}x window:")
        print("      re-run once to see it again, then look at the code the metric covers (--explain).")
    else:
        print("  host check: no declared reference was measured in this run, so the host cannot be read")
        print("      and neither can this failure — the reference line is part of the evidence (--explain).")
    print("Fix the regression, or accept it explicitly with: scripts/check-bench.sh --update --force")

if alloc_breach:
    print(f"FAIL: {len(alloc_breach)} metric(s) over their max_alloc_per_op budget (counted exactly — this is not")
    print("  host noise, and re-running is not the answer):")
    for name, budget, measured in alloc_breach:
        print(f"  [alloc] {name}: budget {budget:.2f} alloc/op → measured {measured:.2f} alloc/op")
    print("  an alloc breach means the timed path grew an allocation; the counting-allocator")
    print("  mirror of the harness is in src/benchmark.zig (the [alloc] section), and the")
    print("  exact per-path contract is asserted in src/runtime/alloc_contract_test.zig.")
    print("  Fix the allocation, or raise the budget in scripts/bench-baseline.json only")
    print("  when the new allocation is deliberate — it is a ratchet, not a snapshot.")

if host_notes:
    print(f"NOTE: a machine reference is more than {threshold}x away from its recorded value (host generation, not code):")
    for line in host_notes:
        print(f"      {line}")

if gone and only is None:
    print(f"WARN: {len(gone)} baseline metric(s) no longer produced: {', '.join(gone)}")
    print("      (removing a benchmark does not fail the gate; run --update to prune)")
if new_metrics and only is None:
    print(f"WARN: {len(new_metrics)} metric(s) not in the baseline: {', '.join(new_metrics)}")
    print("      (run --update to record them)")
if pending and only is None:
    print(f"WARN: {len(pending)} baseline entry/entries hold no number yet — skipped, nothing to compare against:")
    for line in pending:
        print(f"      {line}")
    print("      (this machine class has not recorded them — run --update on it, then review the diff)")
if mismatch and only is None:
    print(f"WARN: {len(mismatch)} metric(s) whose baseline entry and gating list disagree — skipped, not compared:")
    for line in mismatch:
        print(f"      {line}")
if retargeted and only is None:
    print(f"WARN: {len(retargeted)} metric(s) recorded against a different reference than the gating list names — skipped, not compared:")
    for line in retargeted:
        print(f"      {line}")
    print("      (a ratio to another reference is a different unit; re-record it with --update on this machine class)")
if unmeasurable and only is None:
    print(f"WARN: no comparison possible for {', '.join(unmeasurable)} — skipped, nothing to compare against")
if alloc_unmeasured and only is None:
    print(f"WARN: {len(alloc_unmeasured)} alloc budget(s) had no [alloc] row in this run's log — skipped, not judged:")
    for name in alloc_unmeasured:
        print(f"      {name}")

if not slower and not alloc_breach:
    if only is not None:
        print(f"OK (confirm pass): the {len(only)} previously breached metric(s) re-evaluated within "
              f"{threshold}x of the baseline on the second run: {', '.join(sorted(only))}")
    else:
        print(f"OK: {len(cur)} metric(s) within {threshold}x of the baseline (each a median of 3 samples);"
              f" {budgeted - len(alloc_unmeasured)} of {budgeted} alloc budget(s) held"
              + (f", {len(alloc_unmeasured)} unmeasured (WARN above)" if alloc_unmeasured else "") + ".")

if breach_out:
    with open(breach_out, "w") as fh:
        json.dump({"slower": [s[0] for s in slower],
                   "alloc_breach": [a[0] for a in alloc_breach]}, fh)

sys.exit(1 if slower or alloc_breach else 0)
