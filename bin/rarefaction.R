#!/usr/bin/env Rscript

# Alpha-diversity rarefaction curves (Gap 1 from the TBCG2026 QIIME2-course
# gap review, 2026-11-06). Mirrors `qiime diversity alpha-rarefaction`:
# expected feature richness at multiple subsampling depths, per sample,
# with an optional grouping variable for colouring/faceting.
#
# Requires: argparse, data.table, vegan, ggplot2 (env/diversity).

suppressPackageStartupMessages({
    library(argparse)
    library(data.table)
    library(vegan)
    library(ggplot2)
})

parser <- ArgumentParser(description = 'Alpha-diversity rarefaction curves.')
parser$add_argument('--input_asv_counts', type='character', required=TRUE,
                    help='ASV count table TSV (first column = feature ID, columns = samples).')
parser$add_argument('--input_metadata', type='character', required=TRUE,
                    help='Sample metadata TSV (first or "sample-id" column = sample IDs).')
parser$add_argument('--output_dir', type='character', required=TRUE,
                    help='Output directory for curves TSV + PDF.')
parser$add_argument('--grouping_variable', type='character', default=NULL,
                    help='Metadata column to colour/facet the curves by.')
parser$add_argument('--max_depth', type='integer', default=NULL,
                    help='Maximum rarefaction depth. Default: shallowest sample total.')
parser$add_argument('--steps', type='integer', default=30,
                    help='Approximate number of depth steps between 1 and max_depth.')

args <- parser$parse_args()
if (!dir.exists(args$output_dir)) dir.create(args$output_dir, recursive = TRUE)

read_counts <- function(filepath) {
    df <- fread(filepath, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
    mat <- as.matrix(df[, -1, drop = FALSE])
    mode(mat) <- "numeric"
    rownames(mat) <- df[[1]]
    mat
}

counts <- read_counts(args$input_asv_counts)
message(paste("Loaded counts:", nrow(counts), "features x", ncol(counts), "samples."))

# Metadata: sample IDs from 'sample-id' column, else first column
meta <- fread(args$input_metadata, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
id_col <- if ("sample-id" %in% names(meta)) "sample-id" else names(meta)[1]
rownames(meta) <- as.character(meta[[id_col]])

# Align samples
common <- intersect(colnames(counts), rownames(meta))
if (length(common) == 0) {
    stop("No common samples between count table and metadata.")
}
counts <- counts[, common, drop = FALSE]
meta <- meta[common, , drop = FALSE]
message(paste("Retained", length(common), "common samples."))

# Transpose: vegan expects samples as rows
counts_t <- t(counts)
totals <- rowSums(counts_t)
zero_or_empty <- names(totals)[totals == 0]
if (length(zero_or_empty) > 0) {
    message(paste("Excluding", length(zero_or_empty), "empty sample(s):", paste(zero_or_empty, collapse = ", ")))
    counts_t <- counts_t[totals > 0, , drop = FALSE]
}
if (nrow(counts_t) == 0) stop("No samples with non-zero counts.")

max_depth <- if (is.null(args$max_depth)) floor(min(rowSums(counts_t))) else as.integer(args$max_depth)
steps     <- max(2L, as.integer(args$steps))
# Round the step size to a sane integer so depths are readable
step_size <- max(1L, as.integer(round(max_depth / steps)))
floor_step <- max(1L, step_size %/% 20)  # include very shallow depths for the curve toe
depths <- unique(sort(c(seq(1L, max_depth, by = step_size), floor_step, max_depth)))
depths <- depths[depths <= max_depth]
message(paste("Rarefying at", length(depths), "depths up to", max_depth, "reads."))

# vegan::rarefy gives expected richness per subsample (se=FALSE)
sparse_ok <- depths >= 1
rich_list <- lapply(depths, function(d) rarefy(counts_t, sample = d, se = FALSE))
names(rich_list) <- depths
curve_data <- data.table::rbindlist(lapply(names(rich_list), function(d) {
    data.table(sample = rownames(rich_list[[d]]),
               depth  = as.integer(d),
               richness = as.numeric(rich_list[[d]]))
}))

curve_data$observed_full <- as.numeric(rowSums(counts_t)[curve_data$sample])

if (!is.null(args$grouping_variable) && args$grouping_variable %in% names(meta)) {
    curve_data[[args$grouping_variable]] <- as.factor(meta[curve_data$sample, args$grouping_variable])
}

curve_out <- file.path(args$output_dir, "rarefaction_curves.tsv")
fwrite(curve_data, file = curve_out, sep = "\t", quote = FALSE, row.names = FALSE)
message(paste("Saved curve data to:", curve_out))

# Plot
p <- ggplot(curve_data, aes(x = depth, y = richness, group = sample)) +
    labs(title = "Alpha-diversity rarefaction curves (expected richness)",
         x = "Sequencing depth (reads)", y = "Expected ASV richness") +
    theme_minimal() +
    theme(legend.position = "right", axis.text.x = element_text(angle = 0))

if (!is.null(args$grouping_variable) && args$grouping_variable %in% names(curve_data)) {
    p <- p + geom_line(aes(color = .data[[args$grouping_variable]]), alpha = 0.8, linewidth = 0.6)
} else {
    p <- p + geom_line(alpha = 0.6, color = "steelblue")
}

pdf_out <- file.path(args$output_dir, "rarefaction_curves.pdf")
ggsave(pdf_out, p, width = 8, height = 6)
message(paste("Saved rarefaction plot to:", pdf_out))
message("Rarefaction analysis complete.")
