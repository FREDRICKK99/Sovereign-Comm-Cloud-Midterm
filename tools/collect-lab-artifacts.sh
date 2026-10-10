#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
REPO="${1:?Usage: collect-lab-artifacts.sh /path/to/repo}"
LAB="${LAB_ROOT:-/root/genomics-final-experiment}"
mkdir -p "$REPO/results" "$REPO/evidence/manifests" "$REPO/src/federation-agent"
# CSV-only results: manually review source CSVs before publishing; metadata can contain IPs/identifiers.
find "$LAB/results" -maxdepth 1 -type f -name '*.csv' -print0 | while IFS= read -r -d '' file; do
  base="$(basename "$file")"
  case "$base" in
    e1-*) dst=e1-network;;
    e2-e3-*|summary-ddil-*) dst=e2-e3-ddil;;
    e4-*) dst=e4-security;;
    e5-*) dst=e5-sovereignty;;
    *) dst=scale;;
  esac
  mkdir -p "$REPO/results/$dst"
  cp -- "$file" "$REPO/results/$dst/$base"
done
# Metadata-only evidence files from E5. Keep remote IPs in these records under review.
if [ -d "$LAB/e5-sovereignty/network" ]; then
  find "$LAB/e5-sovereignty/network" -mindepth 1 -maxdepth 1 -type d -print0 | while IFS= read -r -d '' run; do
    dest="$REPO/results/e5-sovereignty/$(basename "$run")"
    mkdir -p "$dest"
    for file in job-status.json traffic-summary.csv traffic-summary-corrected.csv nextflow-trace.txt; do
      [ ! -f "$run/$file" ] || cp -- "$run/$file" "$dest/$file"
    done
  done
fi
# Active runner source and Cargo metadata: stage only; inspect before publication.
for file in /home/fredrick/run-all-final-genomics.sh /root/run-all-final-genomics-experiments.sh; do
  if [ -f "$file" ]; then cp -- "$file" "$REPO/scripts/experiments/$(basename "$file")"; fi
done
for file in Cargo.toml Cargo.lock; do
  if [ -f "/home/fredrick/federation-agent/$file" ]; then
    cp -- "/home/fredrick/federation-agent/$file" "$REPO/src/federation-agent/$file"
  fi
done
if [ -f /home/fredrick/federation-agent/src/main.rs ]; then
  cp -- /home/fredrick/federation-agent/src/main.rs "$REPO/src/federation-agent/main.rs.review-required"
fi
# Collect checksums, NOT raw restricted evidence.
find "$REPO/results" -type f -print0 | sort -z | xargs -0 -r sha256sum > "$REPO/evidence/manifests/result-sha256.txt"
find "$REPO" -type f ! -path '*/.git/*' -printf '%P\n' | sort > "$REPO/evidence/manifests/collected-file-inventory.txt"
echo "Staged selected artifacts. Review public-safe data and run tools/prepublish-check.sh; do NOT git add blindly."
