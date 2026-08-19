#!/usr/bin/env python3
"""
summarise_run.py — Generate an AI-friendly JSON summary of a completed eDNA pipeline run.

Reads results from a nf-edna run and writes run_summary.json, which consolidates all
key statistics into a single compact file suitable for AI interpretation without
loading large raw tables into context.

Usage:
    python summarise_run.py --results_dir <path> --run_id <id> [--output <path>]

Example:
    python nf-edna/bin/summarise_run.py \
        --results_dir analyses/2024K1/results \
        --run_id 2024K1-V3 \
        --output analyses/2024K1/results/2024K1-V3/run_summary.json
"""

import argparse
import csv
import gzip
import json
import os
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def read_tsv(path, skip_comment=True):
    """Return list-of-dicts from a TSV or CSV; skip '#' comment lines."""
    path = str(path)
    delim = ',' if path.endswith('.csv') else '\t'
    rows = []
    try:
        with open(path) as f:
            for line in f:
                if skip_comment and line.startswith('#'):
                    continue
                rows.append(line)
        reader = csv.DictReader(rows, delimiter=delim)
        return list(reader)
    except FileNotFoundError:
        return None


def count_fastq_reads(path):
    """Count reads in a plain or gzipped FASTQ (4 lines per read)."""
    try:
        if str(path).endswith('.gz'):
            with gzip.open(path, 'rb') as f:
                return sum(1 for _ in f) // 4
        else:
            with open(path) as f:
                return sum(1 for _ in f) // 4
    except Exception:
        return None


def pct(n, total):
    return round(100 * n / total, 1) if total else None


def round_f(v, digits=4):
    try:
        return round(float(v), digits)
    except (TypeError, ValueError):
        return v


# ---------------------------------------------------------------------------
# Section extractors
# ---------------------------------------------------------------------------

def pipeline_metadata(run_dir):
    state_path = run_dir / "pipeline_state.json"
    try:
        with open(state_path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def read_flow(run_dir, manifest_path):
    """Per-sample read counts: raw (from manifest) and trimmed."""
    result = {}

    # Trimmed reads
    trimmed_dir = run_dir / "qc" / "trimmed"
    if trimmed_dir.exists():
        for sample_dir in sorted(trimmed_dir.iterdir()):
            if not sample_dir.is_dir():
                continue
            sample = sample_dir.name
            fq_files = list(sample_dir.glob("*.trimmed.fastq.gz")) + \
                       list(sample_dir.glob("*.trimmed.fastq"))
            if fq_files:
                result.setdefault(sample, {})["trimmed"] = count_fastq_reads(fq_files[0])

    # Raw reads from manifest
    if manifest_path and Path(manifest_path).exists():
        rows = read_tsv(manifest_path, skip_comment=False)
        if rows:
            for row in rows:
                sample = row.get("sample-id") or row.get("sample_id") or ""
                fp = (row.get("absolute-filepath") or row.get("forward-absolute-filepath")
                      or row.get("read1-filepath") or "")
                if sample and fp and Path(fp).exists():
                    result.setdefault(sample, {})["raw"] = count_fastq_reads(fp)

    return result


def blank_qc(read_flow_dict):
    """Flag blank/negative-control samples whose trimmed reads exceed any biological sample."""
    blank_keys = [s for s in read_flow_dict if "blank" in s.lower() or "neg" in s.lower()]
    bio_keys   = [s for s in read_flow_dict if s not in blank_keys]

    warnings = []
    for blank in blank_keys:
        blank_trimmed = read_flow_dict[blank].get("trimmed")
        if blank_trimmed is None:
            continue
        exceeded = sorted(
            s for s in bio_keys
            if (read_flow_dict[s].get("trimmed") or float("inf")) < blank_trimmed
        )
        if exceeded:
            warnings.append({
                "blank_sample": blank,
                "blank_trimmed_reads": blank_trimmed,
                "biological_samples_with_fewer_reads": exceeded,
            })

    return warnings


def asv_counts(run_dir):
    """ASV counts at each pipeline stage."""
    out = {}
    asv_dir = run_dir / "asv_table"

    for key, filename in [
        ("raw",        "feature-table_renamed.tsv"),
        ("decontam",   "decontam_asv_table.tsv"),
        ("filtered",   "filtered_asv_table.tsv"),
    ]:
        path = asv_dir / filename
        if path.exists():
            with open(path) as f:
                out[key] = sum(1 for _ in f) - 1  # subtract header

    # Contaminants flagged by decontam
    summary_path = asv_dir / "decontam_summary.tsv"
    if summary_path.exists():
        rows = read_tsv(summary_path)
        if rows:
            flagged = sum(1 for r in rows if r.get("Contaminant_Status") == "Yes")
            out["contaminants_flagged"] = flagged

    return out


def taxonomy_stats(run_dir):
    """Classification rates by rank, kingdom distribution, and confidence-filter stats."""
    tax_path = run_dir / "taxonomy" / "idtaxa_classification_confident.tsv"
    rows = read_tsv(tax_path)
    if not rows:
        return {}

    total = len(rows)
    ranks = [c for c in rows[0].keys() if c != "ASV_ID"]

    # Classification rate per rank (non-NA)
    rates = {}
    for rank in ranks:
        classified = sum(1 for r in rows if r.get(rank) and r[rank] != "NA")
        rates[rank] = pct(classified, total)

    # Kingdom distribution
    kingdom_col = "superkingdom" if "superkingdom" in ranks else (ranks[0] if ranks else None)
    kingdoms = {}
    if kingdom_col:
        for r in rows:
            k = r.get(kingdom_col) or "NA"
            kingdoms[k] = kingdoms.get(k, 0) + 1

    # Read loss to kingdom filtering (filtered table vs agglomerated asv_counts)
    read_loss = None
    filtered_table = run_dir / "asv_table" / "filtered_asv_table.tsv"
    agg_counts = run_dir / "taxonomy" / "agglomerated_data" / "asv_counts.tsv"
    if filtered_table.exists() and agg_counts.exists():
        ft_total = _sum_table(filtered_table)
        agg_total = _sum_table(agg_counts)
        if ft_total:
            read_loss = {
                "filtered_table_reads": int(ft_total),
                "agglomerated_reads":   int(agg_total),
                "lost_reads":           int(ft_total - agg_total),
                "lost_pct":             pct(ft_total - agg_total, ft_total),
            }

    # Confidence-filter stats: compare full classification to confident subset
    confidence_filter = None
    full_path = run_dir / "taxonomy" / "idtaxa_classification.tsv"
    if full_path.exists():
        try:
            with open(full_path) as f:
                total_before = sum(1 for _ in f) - 1  # subtract header
            confidence_filter = {
                "total_before_filter": total_before,
                "total_after_filter":  total,
                "lost_to_filter":      total_before - total,
                "pct_lost":            pct(total_before - total, total_before),
            }
        except Exception:
            pass

    return {
        "total_asvs":                  total,
        "classification_rates":        rates,
        "kingdom_distribution":        {k: {"count": n, "pct": pct(n, total)}
                                        for k, n in sorted(kingdoms.items(), key=lambda x: -x[1])},
        "read_loss_to_kingdom_filter": read_loss,
        "confidence_filter":           confidence_filter,
    }


def _sum_table(path):
    """Sum all numeric values in a TSV (excluding first column)."""
    total = 0.0
    try:
        with open(path) as f:
            reader = csv.DictReader(f, delimiter='\t')
            id_col = reader.fieldnames[0]
            for row in reader:
                for k, v in row.items():
                    if k == id_col:
                        continue
                    try:
                        total += float(v)
                    except (TypeError, ValueError):
                        pass
    except Exception:
        pass
    return total


def top_taxa(run_dir, top_n=10):
    """Top N taxa by total reads at each agglomeration rank (phylum, class, family, genus, etc.)."""
    agg_dir = run_dir / "taxonomy" / "agglomerated_data"
    out = {}

    for counts_file in sorted(agg_dir.glob("*_counts.tsv")) if agg_dir.exists() else []:
        if counts_file.name == "asv_counts.tsv":
            continue
        rank = counts_file.stem.replace("_counts", "")
        rows = read_tsv(counts_file)
        if not rows:
            continue

        id_col = list(rows[0].keys())[0]  # "Taxon"
        sample_cols = [k for k in rows[0].keys() if k != id_col]

        taxa_totals = [
            (row.get(id_col, ""), int(sum(_safe_float(row.get(c, 0)) for c in sample_cols)))
            for row in rows
        ]
        taxa_totals.sort(key=lambda x: -x[1])
        grand_total = sum(n for _, n in taxa_totals)

        out[rank] = [
            {"taxon": taxon, "total_reads": n, "pct": pct(n, grand_total)}
            for taxon, n in taxa_totals[:top_n]
        ]

    return out


def alpha_diversity(run_dir):
    """Per-sample alpha diversity metrics."""
    path = run_dir / "diversity" / "alpha" / "alpha_diversity_metrics.tsv"
    rows = read_tsv(path)
    if not rows:
        return {}

    out = {}
    for r in rows:
        sample = r.get("SampleID", "")
        out[sample] = {k: round_f(v) for k, v in r.items() if k != "SampleID"}
    return out


def beta_diversity(run_dir):
    """Beta diversity summary — PERMANOVA and cluster assignments."""
    beta_dir = run_dir / "diversity" / "beta"
    out = {"available_outputs": [], "unavailable": []}

    for f in beta_dir.glob("*.pdf") if beta_dir.exists() else []:
        out["available_outputs"].append(f.name)

    # PERMANOVA
    perm_path = beta_dir / "permanova_results.tsv"
    if perm_path.exists():
        rows = read_tsv(perm_path)
        if rows:
            out["permanova"] = [
                {k: round_f(v) if k not in ("Metric", "Term") else v for k, v in r.items()}
                for r in rows if r.get("Term") not in ("Residual", "Total")
            ]
    else:
        out["unavailable"].append("permanova_results.tsv (diversity stage may not have run)")

    # Cluster assignments
    cluster_path = beta_dir / "sample_clusters.tsv"
    if cluster_path.exists():
        rows = read_tsv(cluster_path)
        if rows:
            out["community_typing"] = {r["SampleID"]: r["Cluster"] for r in rows}
    else:
        out["unavailable"].append("sample_clusters.tsv (diversity stage may not have run)")

    return out


def differential_abundance(run_dir):
    """Differential abundance summary: significant hits, top taxa."""
    da_dir = run_dir / "association" / "differential_abundance"
    path = da_dir / "differential_abundance_results.tsv"
    rows = read_tsv(path)
    if not rows:
        return {"note": "No results file found."}

    q_col   = "qval"
    coef_col = "coef"
    feat_col = "feature"
    meta_col = "metadata"

    significant = [r for r in rows if _is_significant(r.get(q_col), 0.05)]

    top_n = 10
    increased = sorted(
        [r for r in significant if _safe_float(r.get(coef_col), 0) > 0],
        key=lambda r: -abs(_safe_float(r.get(coef_col), 0))
    )[:top_n]
    decreased = sorted(
        [r for r in significant if _safe_float(r.get(coef_col), 0) < 0],
        key=lambda r: -abs(_safe_float(r.get(coef_col), 0))
    )[:top_n]

    def fmt(r):
        return {
            "feature":    r.get(feat_col),
            "comparison": r.get(meta_col, "") + " " + r.get("value", ""),
            "coef":       round_f(r.get(coef_col)),
            "qval":       round_f(r.get(q_col)),
        }

    return {
        "total_tests":        len(rows),
        "significant_q0.05":  len(significant),
        "top_increased":      [fmt(r) for r in increased],
        "top_decreased":      [fmt(r) for r in decreased],
    }


def correlations(run_dir):
    """Feature-feature and feature-metadata correlation summaries."""
    corr_dir = run_dir / "association" / "correlation"
    out = {}

    for level_dir in sorted(corr_dir.iterdir()) if corr_dir.exists() else []:
        if not level_dir.is_dir():
            continue
        level = level_dir.name  # e.g. "correlation_analysis_genus"

        level_out = {}

        # Feature-metadata correlations
        for path in level_dir.glob("feature_metadata_correlations_*.tsv"):
            rows = read_tsv(path)
            if rows:
                level_out["feature_metadata"] = {
                    "significant_count": len(rows),
                    "results": [
                        {
                            "feature":   r.get("Feature"),
                            "variable":  r.get("Metadata_Variable"),
                            "r":         round_f(r.get("Correlation")),
                            "qval":      round_f(r.get("Q_value")),
                        }
                        for r in rows
                    ],
                }

        # Feature-feature correlations (exclude self-correlations)
        for path in level_dir.glob("feature_feature_correlations_*.tsv"):
            rows = read_tsv(path)
            if rows:
                non_self = [r for r in rows if r.get("Feature1") != r.get("Feature2")]
                level_out["feature_feature"] = {
                    "significant_pairs": len(non_self),
                    "top_pairs": [
                        {
                            "feature1": r.get("Feature1"),
                            "feature2": r.get("Feature2"),
                            "r":        round_f(r.get("Correlation")),
                            "qval":     round_f(r.get("Q_value")),
                        }
                        for r in sorted(non_self,
                                        key=lambda r: -abs(_safe_float(r.get("Correlation"), 0)))[:10]
                    ],
                }

        if level_out:
            out[level] = level_out

    return out


def _is_significant(val, threshold):
    try:
        return float(val) < threshold
    except (TypeError, ValueError):
        return False


def _safe_float(val, default=0.0):
    try:
        return float(val)
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Summarise an eDNA pipeline run into AI-friendly JSON.")
    parser.add_argument("--results_dir", required=True, help="Path to the results directory (containing run_id subdir)")
    parser.add_argument("--run_id",      required=True, help="Run ID (e.g. 2024K1-V3)")
    parser.add_argument("--manifest",    default=None,  help="Path to the sample manifest CSV (for raw read counts)")
    parser.add_argument("--output",      default=None,  help="Output JSON path (default: <results_dir>/<run_id>/run_summary.json)")
    args = parser.parse_args()

    run_dir = Path(args.results_dir) / args.run_id
    if not run_dir.exists():
        sys.exit(f"ERROR: results directory not found: {run_dir}")

    out_path = Path(args.output) if args.output else run_dir / "run_summary.json"

    print(f"Summarising {args.run_id} from {run_dir} ...")

    meta  = pipeline_metadata(run_dir)
    manifest = args.manifest or meta.get("params_used", {}).get("input_manifest")

    rf = read_flow(run_dir, manifest)

    notes = []
    if any(v.get("raw") is None for v in rf.values()):
        notes.append(
            "raw read counts are missing — rerun with --manifest <path/to/manifest.csv> "
            "to populate read_flow[sample].raw for all samples."
        )

    summary = {
        "run_id":            args.run_id,
        "pipeline":          meta.get("pipeline"),
        "marker":            meta.get("marker"),
        "completed_stages":  meta.get("completed_stages", []),
        "params":            meta.get("params_used", {}),
        "read_flow":         rf,
        "blank_qc":          blank_qc(rf),
        "asv_counts":        asv_counts(run_dir),
        "taxonomy":          taxonomy_stats(run_dir),
        "top_taxa":          top_taxa(run_dir),
        "alpha_diversity":   alpha_diversity(run_dir),
        "beta_diversity":    beta_diversity(run_dir),
        "differential_abundance": differential_abundance(run_dir),
        "correlations":      correlations(run_dir),
        "notes":             notes,
    }

    with open(out_path, "w") as f:
        json.dump(summary, f, indent=2)

    print(f"Written: {out_path}")

    # Print a brief console summary
    asv = summary["asv_counts"]
    tax = summary["taxonomy"]
    da  = summary["differential_abundance"]
    print(f"  ASVs: {asv.get('raw','?')} raw → {asv.get('filtered','?')} filtered "
          f"({asv.get('contaminants_flagged','?')} contaminants removed)")
    print(f"  Taxonomy NA rate: {tax.get('classification_rates',{}).get('superkingdom','?')}% classified at kingdom")
    print(f"  Read loss to kingdom filter: {tax.get('read_loss_to_kingdom_filter',{}).get('lost_pct','?')}%")
    print(f"  DA significant (q<0.05): {da.get('significant_q0.05','?')} / {da.get('total_tests','?')} tests")


if __name__ == "__main__":
    main()
