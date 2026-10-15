#!/usr/bin/env python3
from pathlib import Path
from collections import Counter
import argparse, json, os, random

ROOT = Path(__file__).resolve().parent
SEED = ROOT / "seed_model.json"
STRICT = ROOT / "runtime/blockbot_calibration/strict.jsonl"
MODEL = ROOT / "blockbot_empirical_trays_merged.seed.tsv"
STATE = ROOT / "active_collection_state.json"
STATUS = ROOT / "active_collection_status.json"

ap = argparse.ArgumentParser()
ap.add_argument("--epoch", type=int, required=True)
args = ap.parse_args()
seed = json.loads(SEED.read_text())
hypotheses = list(seed["selected_shapes"])

piece_counts = Counter({k: int(v) for k, v in seed["observed_piece_counts"].items()})
tray_counts = Counter()
for k, v in seed.get("observed_tray_counts", {}).items():
    vals = tuple(k.split("|"))
    if len(vals) == 3:
        tray_counts[tuple(sorted(vals))] += int(v)
seen_rows = set()
if STRICT.exists():
    for line in STRICT.read_text(errors="ignore").splitlines():
        try:
            row = json.loads(line)
        except Exception:
            continue
        if row.get("mode") != "generator_observation":
            continue
        vals = str(row.get("pieces", "")).split("|")
        if len(vals) != 3 or any(not x for x in vals):
            continue
        signature = (str(row.get("boardBits")), tuple(vals), row.get("verified"), row.get("round"))
        if signature in seen_rows:
            continue
        seen_rows.add(signature)
        piece_counts.update(vals)
        tray_counts[tuple(sorted(vals))] += 1

state = json.loads(STATE.read_text()) if STATE.exists() else {"target_exposures": {}}
exposures = Counter({k: int(v) for k, v in state.get("target_exposures", {}).items()})
observed = {x for x, n in piece_counts.items() if n > 0}
unobserved = [x for x in hypotheses if x not in observed]
def target_rank(shape):
    rows = shape.split("/")
    cells = sum(r.count("1") for r in rows)
    return (exposures[shape], cells, len(rows) * len(rows[0]), shape)
ranked_targets = sorted(unobserved, key=target_rank)
# A one-cell gap is the strongest active lure and the 1x1 piece is the
# only high-confidence real game shape not observed yet. Keep it targeted.
priority_targets = ["1"] if "1" in unobserved else []
targets = priority_targets + [x for x in ranked_targets if x not in priority_targets]
targets = targets[:1]
for shape in targets:
    exposures[shape] += 1
novel = sorted(observed - set(hypotheses))
all_shapes = hypotheses + novel
weights = {}
for shape in all_shapes:
    if shape in targets:
        weights[shape] = 180
    elif shape in unobserved:
        weights[shape] = 12
    else:
        # Final model: empirical frequency from all deduplicated live trays
        # plus the fixed historical seed, not a flat weight of one.
        weights[shape] = max(1, piece_counts[shape])

model_trays = Counter()
for tray, count in tray_counts.items():
    if all(x in weights for x in tray):
        model_trays[tray] += min(20, max(1, count))
rng = random.Random(5743 + args.epoch)
for _ in range(1400):
    if targets and rng.random() < 0.80:
        vals = [rng.choice(targets), rng.choice(all_shapes), rng.choice(all_shapes)]
    elif unobserved:
        vals = [rng.choice(unobserved), rng.choice(all_shapes), rng.choice(all_shapes)]
    else:
        population = list(all_shapes)
        sample_weights = [max(1, piece_counts[x]) for x in population]
        vals = rng.choices(population, weights=sample_weights, k=3)
    model_trays[tuple(sorted(vals))] += 1

lines = [f"S\t{x}\t{weights[x]}" for x in all_shapes]
lines.extend("T\t" + "\t".join(t) + f"\t{n}" for t, n in sorted(model_trays.items()))
tmp = MODEL.with_name(MODEL.name + ".tmp")
tmp.write_text("\n".join(lines) + "\n")
os.replace(tmp, MODEL)
state = {
    "epoch": args.epoch,
    "target_exposures": dict(exposures),
    "last_targets": targets,
}
STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n")
status = {
    "epoch": args.epoch,
    "observed_hypotheses": len(observed & set(hypotheses)),
    "hypothesis_count": len(hypotheses),
    "remaining_hypotheses": unobserved,
    "targets": targets,
    "novel_shapes": novel,
    "actual_observation_rows": len(seen_rows),
    "actual_tray_types": len(tray_counts),
    "model_tray_types": len(model_trays),
    "real_shape_count": len(all_shapes),
    "empirical_piece_observations": sum(piece_counts[x] for x in all_shapes),
    "excluded_hypotheses": seed.get("excluded_hypotheses", []),
    "piece_probabilities": {x: piece_counts[x] / max(1, sum(piece_counts[y] for y in all_shapes)) for x in all_shapes},
}
STATUS.write_text(json.dumps(status, ensure_ascii=False, indent=2) + "\n")
with (ROOT / "observed_shapes.tsv").open("w") as fh:
    for shape, count in sorted(piece_counts.items(), key=lambda x: (-x[1], x[0])):
        fh.write(f"{shape}\t{count}\n")
print(json.dumps(status, ensure_ascii=False))
