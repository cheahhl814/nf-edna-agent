#!/usr/bin/env Rscript

# Grouped alpha-diversity boxplots (Gap 5 from the TBCG2026 QIIME2-course gap
# review, 2026-11-06). Mirrors the course's Qiime2R-boxplotalpha.R figure:
# one violin+box panel per alpha metric, coloured by a grouping variable,
# with optional pairwise significance annotations.
#
# Input: the diversity-stage alpha_diversity_metrics.tsv (edna-agent) or any
# TSV with a SampleID column + numeric metric columns.
#
# Requires: argparse, data.table, ggplot2 (rstatix/ggpubr optional; env/visualization).

suppressPackageStartupMessages({
    library(argparse)
    library(data.table)
    library(ggplot2)
})

parser <- ArgumentParser(description = 'Grouped alpha-diversity boxplots from a metrics TSV.')
parser$add_argument('--input_alpha_metrics', type='character', required=TRUE,
                    help='Alpha-diversity metrics TSV (SampleID column + metric columns).')
parser$add_argument('--input_metadata', type='character', required=TRUE,
                    help='Sample metadata TSV.')
parser$add_argument('--group_by', type='character', required=TRUE,
                    help='Metadata column to group by (e.g. INDO_REGION).')
parser$add_argument('--metrics', type='character', default='observed,shannon,faith,pielou',
                    help='Comma-separated metrics to plot; missing columns are skipped.')
parser$add_argument('--output_dir', type='character', required=TRUE,
                    help='Output directory for the PDFs.')
parser$add_argument('--significance', type='character', default='auto',
                    help='"auto" (default): add pairwise Wilcoxon annotations when rstatix is available and groups allow it; "off" never.')

args <- parser$parse_args()
if (!dir.exists(args$output_dir)) dir.create(args$output_dir, recursive = TRUE)

metrics_df <- fread(args$input_alpha_metrics, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
if (!"SampleID" %in% names(metrics_df)) stop("Metrics TSV must have a 'SampleID' column.")

meta <- fread(args$input_metadata, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
id_col <- if ("sample-id" %in% names(meta)) "sample-id" else names(meta)[1]
meta[[id_col]] <- as.character(meta[[id_col]])
if (!args$group_by %in% names(meta)) {
    stop(paste("Grouping column not found in metadata:", args$group_by))
}

merged <- merge(metrics_df, meta[, c(id_col, args$group_by), drop = FALSE],
                by.x = "SampleID", by.y = id_col)
merged[[args$group_by]] <- factor(merged[[args$group_by]])
message(paste("Merged metrics for", nrow(merged), "samples by", args$group_by, "with levels:",
              paste(levels(merged[[args$group_by]]), collapse = ", ")))

requested <- trimws(unlist(strsplit(args$metrics, ",")))
plot_list <- list()
for (metric in requested) {
    if (!metric %in% names(merged)) {
        warning(paste("Metric column not present, skipping:", metric))
        next
    }
    plot_df <- merged[!is.na(merged[[metric]]), , drop = FALSE]
    if (nrow(plot_df) == 0) { warning(paste("No non-NA values for", metric)); next }

    p <- ggplot(plot_df, aes(x = .data[[args$group_by]], y = .data[[metric]], fill = .data[[args$group_by]])) +
        geom_violin(alpha = 0.5, scale = "width") +
        geom_boxplot(width = 0.15, fill = "white", outlier.shape = 21) +
        labs(title = paste(metric, "by", args$group_by),
             x = args$group_by, y = metric, fill = args$group_by) +
        theme_minimal() +
        theme(axis.text.x = element_text(angle = 45, hjust = 1), legend.position = "none")

    if (args$significance == "auto" && requireNamespace("rstatix", quietly = TRUE) &&
        requireNamespace("ggpubr", quietly = TRUE) &&
        nlevels(plot_df[[args$group_by]]) >= 2 && nrow(plot_df) >= 4) {
        safe_metric <- paste0("m_", make.names(metric))
        safe_group  <- paste0("g_", make.names(args$group_by))
        df_safe <- plot_df
        names(df_safe)[names(df_safe) == metric] <- safe_metric
        names(df_safe)[names(df_safe) == args$group_by] <- safe_group
        stat_test <- tryCatch(
            suppressWarnings(rstatix::wilcox_test(df_safe, stats::as.formula(paste(safe_metric, "~", safe_group)))) |>
                rstatix::adjust_pvalue(method = "fdr") |>
                rstatix::add_significance() |>
                ggpubr::add_xy_position(formula = stats::as.formula(paste(safe_metric, "~", safe_group)), data = df_safe, fun = "max"),
            error = function(e) data.frame())
        if (nrow(stat_test) > 0) {
            p <- p + ggpubr::stat_pvalue_manual(stat_test, label = "p.adj.signif", tip.length = 0.01)
        }
    }

    out <- file.path(args$output_dir, paste0("alpha_boxplot_", metric, ".pdf"))
    ggsave(out, p, width = 6.5, height = 6)
    plot_list[[metric]] <- out
    message(paste("Saved", out))
}
if (length(plot_list) == 0) stop("No metrics were plottable — check --metrics against the TSV columns.")
message("Alpha boxplots complete.")
