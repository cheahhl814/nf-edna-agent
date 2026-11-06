#!/usr/bin/env Rscript

# Consensus-BLAST taxonomic assignment (Gap 3 from the TBCG2026 QIIME2-course
# gap review, 2026-11-06). Mirrors `qiime feature-classifier
# classify-consensus-blast` semantics (perc-identity + query-cov + maxaccepts
# + min-consensus), implemented with vsearch --usearch_global for the search
# step and this script for the per-query majority-vote consensus.
# Output format matches bin/idtaxa_rds.R exactly (SequenceID + the seven
# lowercase rank columns + confidence TSV), so bin/filter_idtaxa_by_confidence.jl
# and bin/agglomerate_data.R consume it unchanged.
#
# Requires: argparse, data.table (env/classification).

suppressPackageStartupMessages({
    library(argparse)
    library(data.table)
})

RANK_CODES <- c(k = "superkingdom", d = "superkingdom",  # k__ (RDP) and d__ (Mitohelper/NCBI) both mean superkingdom
                p = "phylum", c = "class", o = "order",
                f = "family", g = "genus", s = "species")
RANK_ORDER <- unname(RANK_CODES)

parser <- ArgumentParser(description = 'Consensus taxonomic assignment from vsearch blast6out against a labelled reference database.')
parser$add_argument('--blast6out', type='character', required=TRUE,
                    help='vsearch --usearch_global --blast6out file (12 tab-separated fields per accepted hit).')
parser$add_argument('--reference_taxonomy', type='character', required=TRUE,
                    help='Reference taxonomy TSV: either [ID, lineage] with RDP rank codes (k__..;p__..;) or ID + one column per rank.')
parser$add_argument('--output_classification', type='character', required=TRUE,
                    help='Output classification TSV (SequenceID + rank columns). Overwrites the idtaxa-style filename for a drop-in run.')
parser$add_argument('--output_confidence', type='character', required=TRUE,
                    help='Output confidence TSV (percent-scale vote share per rank, to match the IDTAXA threshold filter).')
parser$add_argument('--min_consensus', type='double', default=0.8,
                    help='Minimum share of assigned hits that must agree per rank (0-1). Mirrors classify-consensus-blast --p-min-consensus.')
parser$add_argument('--unassigned_label', type='character', default='',
                    help='Value written for ranks without a passing consensus.')

args <- parser$parse_args()

# --- Load hits ---------------------------------------------------------------
hits <- fread(args$blast6out, sep = "\t", header = FALSE, data.table = FALSE,
              col.names = c("qseqid", "sseqid", "pident", "length", "mismatch",
                            "gapopen", "qstart", "qend", "sstart", "send",
                            "evalue", "bitscore"))
message(paste("Loaded", nrow(hits), "accepted hits for", length(unique(hits$qseqid)), "unique queries."))
if (nrow(hits) == 0) {
    stop("blast6out file is empty — check vsearch parameters (id/query-cov) and the reference FASTA.")
}

# --- Load reference taxonomy -------------------------------------------------
# Two accepted layouts:
#   (a) ID + single lineage column: "k__Bacteria; p__Proteobacteria; ..."
#   (b) ID + one column per rank (any case: Kingdom/superkingdom/Genus/...)
ref <- fread(args$reference_taxonomy, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
if (ncol(ref) < 2) {
    stop("Reference taxonomy needs >= 2 columns (ID + lineage, or ID + rank columns).")
}
names(ref)[1] <- "ref_id"

ref_map <- list()
if (sum(grepl(";", as.character(ref[[2]]))) > 0) {
    # Layout (a): rank-coded lineage strings
    for (i in seq_len(nrow(ref))) {
        parts <- unlist(strsplit(as.character(ref[i, 2]), "\\s*;\\s*"))
        entry <- list()
        for (part in parts) {
            code <- substr(part, 1, 1); val <- substr(part, 4, nchar(part))  # after "k__"
            val <- trimws(val)
            if (code %in% names(RANK_CODES) && val != "" && !grepl("^unassigned$", val)) {
                entry[[RANK_CODES[[code]]]] <- val
            }
        }
        ref_map[[as.character(ref[i, 1])]] <- entry
    }
} else {
    # Layout (b): per-rank columns
    rank_cols <- intersect(tolower(names(ref)[-1]), RANK_ORDER)
    if (length(rank_cols) == 0) {
        stop("Reference taxonomy columns are neither rank-coded lineages nor rank names (", paste(RANK_ORDER, collapse=","), ").")
    }
    col_lookup <- unlist(lapply(rank_cols, function(rc) tolower(names(ref)[-1]) == rc))
    for (i in seq_len(nrow(ref))) {
        entry <- list()
        for (rc in RANK_ORDER) {
            idx <- which(tolower(names(ref)[-1]) == rc)
            if (length(idx) == 1L) {
                val <- trimws(as.character(ref[i, idx + 1]))
                if (val != "" && !grepl("^unassigned$", val)) entry[[rc]] <- val
            }
        }
        ref_map[[as.character(ref[i, 1])]] <- entry
    }
}
message(paste("Parsed", length(ref_map), "reference taxonomy entries."))

unmapped <- setdiff(unique(hits$sseqid), names(ref_map))
if (length(unmapped) > 0) {
    warning(paste(length(unmapped), "hit IDs have no reference taxonomy entry (e.g.", paste(head(unmapped, 3), collapse = ", "), ") — dropped from consensus."))
}
hits <- hits[hits$sseqid %in% names(ref_map), , drop = FALSE]
if (nrow(hits) == 0) {
    stop("No accepted hits remain with a resolvable reference taxonomy — check reference_taxonomy ID format.")
}

# --- Per-query consensus -----------------------------------------------------
all_queries <- unique(sort(unique(hits$qseqid)))
results <- vector("list", length(all_queries))
conf <- vector("list", length(all_queries))

hit_rows <- split(seq_len(nrow(hits)), hits$qseqid)
for (qi in seq_along(all_queries)) {
    q <- all_queries[qi]
    rows <- hit_rows[[q]]
    taxon_row <- stats::setNames(rep(args$unassigned_label, length(RANK_ORDER)), RANK_ORDER)
    conf_row  <- stats::setNames(rep(0, length(RANK_ORDER)), RANK_ORDER)
    for (rank in RANK_ORDER) {
        vals <- vapply(rows, function(r) as.character(ref_map[[hits$sseqid[[r]]]][[rank]] %||% ""), "")
        vals <- vals[vals != ""]
        if (length(vals) == 0) next
        tbl <- sort(table(vals), decreasing = TRUE)
        top_val <- names(tbl)[1]
        share <- tbl[1] / length(vals)
        if (share >= args$min_consensus) {
            taxon_row[rank] <- top_val
            conf_row[rank]  <- round(100 * share, 2)  # percent scale to match IDTAXA confidence filter
        }
    }
    results[[qi]] <- as.list(c(SequenceID = q, taxon_row))
    conf[[qi]]    <- as.list(c(SequenceID = q, conf_row))
}

classification_df <- rbindlist(results, use.names = TRUE, fill = TRUE)
confidence_df     <- rbindlist(conf,    use.names = TRUE, fill = TRUE)

write.table(classification_df, file = args$output_classification, sep = "\t",
            quote = FALSE, row.names = FALSE, col.names = TRUE)
write.table(confidence_df,     file = args$output_confidence,     sep = "\t",
            quote = FALSE, row.names = FALSE, col.names = TRUE)

n_assigned <- sum(classification_df$genus != args$unassigned_label)
message(paste("Consensus classification written:", n_assigned, "/", nrow(classification_df),
              "ASVs assigned at genus level (min_consensus =", args$min_consensus, ")."))
message("Consensus-BLAST classification complete.")
