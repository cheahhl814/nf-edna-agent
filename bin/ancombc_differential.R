#!/usr/bin/env Rscript

# ANCOM-BC differential abundance (Gap 4 from the TBCG2026 QIIME2-course gap
# review, 2026-11-06). Alternative to Maaslin2: compositional-bias-corrected
# log-fold changes, mirroring `qiime composition ancombc` semantics.
#
# Input: ASV-level counts + per-ASV taxonomy + metadata. The script collapses
# to --level_to_analyze (default Genus, like the course's taxa collapse
# --p-level 6) and runs ANCOM-BC via the Bioconductor ANCOMBC package.
#
# Requires: argparse, data.table, ggplot2, Bioconductor ANCOMBC + TSE (env/association).

suppressPackageStartupMessages({
    library(argparse)
    library(data.table)
    library(ggplot2)
    library(TreeSummarizedExperiment)
    library(S4Vectors)
})

parser <- ArgumentParser(description = 'ANCOM-BC differential abundance (collapses to a taxonomic level, corrects sampling-fraction bias).')
parser$add_argument('--input_asv_counts', type='character', required=TRUE,
                    help='ASV count table TSV (first column = ASV_ID).')
parser$add_argument('--input_asv_taxonomy', type='character', required=TRUE,
                    help='ASV taxonomy table TSV (first column = ASV_ID, rank columns).')
parser$add_argument('--input_metadata', type='character', required=TRUE,
                    help='Sample metadata TSV.')
parser$add_argument('--grouping_variable', type='character', required=TRUE,
                    help='Metadata column for the ANCOM-BC fixed effect (e.g. INDO_REGION).')
parser$add_argument('--reference_level', type='character', default=NULL,
                    help='Baseline factor level (e.g. the course uses Aceh as reference). NULL = first factor level.')
parser$add_argument('--level_to_analyze', type='character', default='Genus',
                    help='Taxonomic rank to collapse to (Genus/Species/Family/...; ASV = no collapse).')
parser$add_argument('--padj_threshold', type='double', default=0.05,
                    help='Adjusted-p threshold for the DA barplot.')
parser$add_argument('--output_dir', type='character', required=TRUE,
                    help='Output directory.')

args <- parser$parse_args()
if (!dir.exists(args$output_dir)) dir.create(args$output_dir, recursive = TRUE)

read_table_tsv <- function(filepath) {
    df <- fread(filepath, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
    rownames(df) <- df[[1]]
    df[[1]] <- NULL
    df
}

counts_df  <- read_table_tsv(args$input_asv_counts)
taxonomy_df<- read_table_tsv(args$input_asv_taxonomy)
meta_df <- fread(args$input_metadata, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
id_col <- if ("sample-id" %in% names(meta_df)) "sample-id" else names(meta_df)[1]
rownames(meta_df) <- as.character(meta_df[[id_col]])
meta_df[[id_col]] <- NULL

common_samples <- intersect(colnames(counts_df), rownames(meta_df))
common_features <- intersect(rownames(counts_df), rownames(taxonomy_df))
if (length(common_samples) == 0 || length(common_features) == 0) {
    stop("No common samples/features between counts, taxonomy, and metadata.")
}
counts_df <- counts_df[common_features, common_samples, drop = FALSE]
taxonomy_df <- taxonomy_df[common_features, , drop = FALSE]
meta_df <- meta_df[common_samples, , drop = FALSE]
message(paste("Aligned:", length(common_features), "features x", length(common_samples), "samples."))

counts_mat <- as.matrix(counts_df)
mode(counts_mat) <- "numeric"

if (!args$grouping_variable %in% names(meta_df)) {
    stop(paste("Grouping variable not found in metadata:", args$grouping_variable))
}
group_var_safe <- "ancombc_group"
meta_df[[group_var_safe]] <- factor(meta_df[[args$grouping_variable]])
if (!is.null(args$reference_level)) {
    if (!args$reference_level %in% levels(meta_df[[group_var_safe]])) {
        stop(paste("reference_level not a factor level:", args$reference_level))
    }
    meta_df[[group_var_safe]] <- relevel(meta_df[[group_var_safe]], ref = args$reference_level)
    message(paste("Baseline (reference) level set to:", args$reference_level))
}
meta_df <- meta_df[, group_var_safe, drop = FALSE]  # ancombc reads all colData columns

# --- Collapse to the requested rank (case-insensitive, manual summing) --------
lvl <- tolower(args$level_to_analyze)
if (lvl != "asv") {
    rank_col <- intersect(tolower(names(taxonomy_df)), lvl)
    if (length(rank_col) != 1L) {
        stop(paste("Rank column not found in taxonomy (want", lvl, "; have:", paste(names(taxonomy_df), collapse=","), ")"))
    }
    rank_col_name <- names(taxonomy_df)[which(tolower(names(taxonomy_df)) == lvl)]
    rank_vals <- taxonomy_df[[rank_col_name]]
    agglom_idx <- which(!is.na(rank_vals) & nzchar(rank_vals))
    if (length(agglom_idx) == 0) {
        stop(paste("No ASVs assigned at rank", lvl, "— cannot collapse."))
    }
    agg_counts <- do.call(rbind, lapply(sort(unique(rank_vals[agglom_idx])), function(tx) {
        colSums(counts_mat[agglom_idx[rank_vals[agglom_idx] == tx], , drop = FALSE])
    }))
    rownames(agg_counts) <- sort(unique(rank_vals[agglom_idx]))
    message(paste("Collapsed to", lvl, "level:", nrow(agg_counts), "features."))
    counts_mat <- agg_counts
}

tse <- TreeSummarizedExperiment(
    assays  = SimpleList(counts = counts_mat),
    colData = S4Vectors::DataFrame(meta_df, check.names = FALSE)
)

# --- Run ANCOMBC --------------------------------------------------------------
if (!requireNamespace("ANCOMBC", quietly = TRUE)) {
    stop("Bioconductor package ANCOMBC not available — pixi add --manifest-path env/association/pixi.toml bioconductor-ancombc")
}
library(ANCOMBC)

# NOTE (F21): this ANCOMBC build parses the formula string as bare variable
# names — " + 1" gets read as a metadata variable "1". Pass no intercept term.
formula <- group_var_safe
# API drift (battle-test round 4, F19): installed ancombc() takes underscore
# args (assay_name, prv_cut, conserve, formula); older Bioc builds used
# fix_formula/zero_cut/conservative. Try the observed signature first, then
# the legacy one; pick result columns dynamically (res$res vs res$lfc + q_val).
res <- tryCatch(
    ancombc(data = tse, assay_name = "counts", formula = formula,
            p_adj_method = "fdr", prv_cut = 0.1, lib_cut = 0,
            conserve = FALSE, neg_lb = FALSE),
    error = function(e) {
        message(paste("ancombc(assay_name/formula) failed (", conditionMessage(e), ") — retrying with legacy fix_formula/zero_cut/conservative signature."))
        ancombc(data = tse, assay.name = "counts", fix_formula = formula,
                p_adj_method = "fdr", zero_cut = 0.90, lib_cut = 0,
                conservative = FALSE, neg_lb = FALSE)
    }
)

lfc_df <- NULL; p_col <- NA; q_col <- NA
if (is.null(res$res)) {
    if (!is.null(res$lfc)) { lfc_df <- res$lfc }
} else if (is.list(res$res) && !is.data.frame(res$res)) {
    # F22: res$res is a LIST of per-statistic frames (lfc/se/W/p_val/q_val/diff_abn)
    lfc_df <- res$res$lfc; p_val_df <- res$res$p_val; q_val_df <- res$res$q_val
} else {
    lfc_df <- res$res
}
if (is.null(lfc_df)) stop("Unexpected ANCOMBC result structure — no $res or $lfc data frame.")
message(paste("ANCOMBC result columns:", paste(names(lfc_df), collapse = ", ")))

ref_level <- levels(tse[[group_var_safe]])[1]
alt_level <- levels(tse[[group_var_safe]])[2]
beta_col <- grep(paste0("^beta", "(.\\|_)?", group_var_safe), names(lfc_df), value = TRUE)[1]
if (is.null(beta_col) || is.na(beta_col)) beta_col <- names(lfc_df)[2]  # first coefficient column
coef_col <- beta_col
p_col  <- intersect(c("p_val", "p"), names(lfc_df))[1]
q_col  <- intersect(c("q_val", "q", "padj"), names(lfc_df))[1]
tax_col <- intersect(c("taxon", "Taxon", "taxa"), names(lfc_df))[1]

p_vals  <- if (!is.na(p_col)) lfc_df[[p_col]] else if (exists("p_val_df")) p_val_df[[2]] else NA
q_vals  <- if (!is.na(q_col)) lfc_df[[q_col]] else NA_real_
if (exists("q_val_df")) {
    q_cand <- intersect(c("q_val", "q"), names(q_val_df))[1]
    q_vals <- if (!is.na(q_cand)) q_val_df[[q_cand]] else q_val_df[[2]]
}
lfc_vals <- as.numeric(lfc_df[[beta_col]])
diff <- data.frame(Taxon = lfc_df[[tax_col]],
                   log_fold_change = lfc_vals,
                   p_value = NA_real_,
                   p_adj   = NA_real_,
                   check.names = FALSE)
diff$p_value <- as.numeric(p_vals)
diff$p_adj   <- as.numeric(q_vals)
diff$Taxon <- as.character(diff$Taxon)
diff$direction <- ifelse(is.na(diff$log_fold_change), NA,
                         ifelse(diff$log_fold_change > 0,
                                paste0("higher_in_", alt_level),
                                paste0("higher_in_", ref_level)))

out_file <- file.path(args$output_dir, "ancombc_results.tsv")
fwrite(diff, file = out_file, sep = "\t", quote = FALSE, row.names = FALSE)
message(paste("ANCOM-BC results written:", out_file))

# --- DA barplot of significant taxa (mirrors qiime composition da-barplot) ----
sig <- diff[!is.na(diff$p_adj) & diff$p_adj <= args$padj_threshold, , drop = FALSE]
sig <- sig[order(sig$log_fold_change, decreasing = FALSE), , drop = FALSE]
if (nrow(sig) > 0) {
    sig$Taxon <- factor(sig$Taxon, levels = rev(sig$Taxon))
    p <- ggplot(sig, aes(x = log_fold_change, y = Taxon, fill = ifelse(log_fold_change > 0, "pos", "neg"))) +
        geom_bar(stat = "identity") +
        labs(title = paste0("ANCOM-BC differential abundance (", coef_col, " vs ", ref_level, ", padj <= ", args$padj_threshold, ")"),
             x = "Bias-corrected log-fold change", y = NULL) +
        scale_fill_manual(values = c("pos" = "#E5851F", "neg" = "#2F6CA3"), guide = "none") +
        theme_minimal()
    ggsave(file.path(args$output_dir, "ancombc_da_barplot.pdf"), p, width = 8, height = max(4, 0.3 * nrow(sig)))
    message(paste(nrow(sig), "significant taxa plotted."))
} else {
    message(paste("No significant taxa at padj <=", args$padj_threshold, "— barplot skipped."))
}
message("ANCOM-BC differential abundance complete.")
