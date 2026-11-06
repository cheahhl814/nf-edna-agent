#!/usr/bin/env Rscript

# PCoA ordination plot with optional PERMANOVA annotation (Gap 5 from the
# TBCG2026 QIIME2-course gap review, 2026-11-06). Mirrors the course's
# `03_core-metrics-results` PCoA/Emperor views in a static, publication-ready
# form: cmdscale-based principal coordinates on Bray-Curtis / Jaccard
# (vegdist) or weighted/unweighted UniFrac (rbiom, when a tree is supplied).
#
# Requires: argparse, data.table, ggplot2, vegan (env/visualization;
# rbiom optional for UniFrac).

suppressPackageStartupMessages({
    library(argparse)
    library(data.table)
    library(ggplot2)
    library(vegan)
})

parser <- ArgumentParser(description = 'PCoA ordination plot + PERMANOVA from an ASV count table.')
parser$add_argument('--input_asv_counts', type='character', required=TRUE,
                    help='Count table TSV (first column = feature ID, samples as columns). Agglomerated (e.g. genus) tables work too.')
parser$add_argument('--input_metadata', type='character', required=TRUE,
                    help='Sample metadata TSV.')
parser$add_argument('--group_by', type='character', default=NULL,
                    help='Metadata column to colour points by.')
parser$add_argument('--distance', type='character', default='bray',
                    help='Distance metric: bray | jaccard | unifrac (weighted/unweighted) | wunifrac.')
parser$add_argument('--input_tree', type='character', default=NULL,
                    help='Rooted Newick tree — required when --distance is unifrac/wunifrac.')
parser$add_argument('--permanova', type='character', default='auto',
                    help='"auto": run adonis2 on the grouping variable when >= 2 groups and >= 2 samples per group.')
parser$add_argument('--output_dir', type='character', required=TRUE,
                    help='Output directory.')

args <- parser$parse_args()
if (!dir.exists(args$output_dir)) dir.create(args$output_dir, recursive = TRUE)

df <- fread(args$input_asv_counts, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
counts_mat <- as.matrix(df[, -1, drop = FALSE]); mode(counts_mat) <- "numeric"
rownames(counts_mat) <- df[[1]]

meta <- fread(args$input_metadata, sep = "\t", header = TRUE, data.table = FALSE, check.names = FALSE)
id_col <- if ("sample-id" %in% names(meta)) "sample-id" else names(meta)[1]
rownames(meta) <- as.character(meta[[id_col]])
meta[[id_col]] <- NULL

common <- intersect(colnames(counts_mat), rownames(meta))
if (length(common) == 0) stop("No common samples between counts and metadata.")
counts_mat <- counts_mat[, common, drop = FALSE]
meta <- meta[common, , drop = FALSE]
counts_mat <- counts_mat[rowSums(counts_mat) > 0, , drop = FALSE]
message(paste("Ordination:", nrow(counts_mat), "features x", ncol(counts_mat), "samples; distance =", args$distance))

dist_obj <- NULL
if (args$distance %in% c("unifrac", "wunifrac")) {
    if (is.null(args$input_tree) || !file.exists(args$input_tree)) {
        stop("UniFrac requires --input_tree pointing to a rooted Newick file.")
    }
    if (!requireNamespace("rbiom", quietly = TRUE)) {
        stop("rbiom not available in this env — required for UniFrac distances.")
    }
    phy <- rbiom::as_phyloseq(otu_table = t(counts_mat), tree = args$input_tree)
    if ("phyloseq" %in% class(phy)) {
        dist_obj <- phyloseq::distance(phy, method = ifelse(args$distance == "unifrac", "unifrac", "wunifrac"))
    } else {
        tree <- ape::read.tree(args$input_tree)
        dist_obj <- rbiom::unifrac(as.data.frame(t(counts_mat)), tree = tree, weighted = args$distance == "wunifrac")
        class(dist_obj) <- "dist"
    }
} else {
    method <- switch(args$distance,
                     bray = "bray", jaccard = "jaccard",
                     stop(paste("Unsupported distance:", args$distance)))
    dist_obj <- vegdist(t(counts_mat), method = method)
}

pcoa <- cmdscale(as.matrix(dist_obj), k = min(2, ncol(counts_mat) - 1), eig = TRUE, add = TRUE)
expl <- sum(pcoa$eig[1:2]) / sum(abs(pcoa$eig[pcoa$eig > 0]))
coord <- data.frame(SampleID = rownames(pcoa$points),
                    Axis1 = pcoa$points[, 1], Axis2 = pcoa$points[, 2])
coord <- merge(coord, meta, by.x = "SampleID", by.y = "row.names", all.x = TRUE)

fwrite(coord, file = file.path(args$output_dir, paste0("pcoa_coordinates_", args$distance, ".tsv")),
       sep = "\t", quote = FALSE, row.names = FALSE)

p <- ggplot(coord, aes(x = Axis1, y = Axis2)) +
    labs(title = paste0("PCoA (", args$distance, ") — Axis1 ",
                        round(100 * pcoa$eig[1] / sum(abs(pcoa$eig[pcoa$eig > 0])), 1), "%, Axis2 ",
                        round(100 * pcoa$eig[2] / sum(abs(pcoa$eig[pcoa$eig > 0])), 1), "%"),
         x = paste0("PCo1 (", round(100 * expl, 1), "% variance)"),
         y = "PCo2") +
    theme_minimal()

if (!is.null(args$group_by) && args$group_by %in% names(coord)) {
    coord[[args$group_by]] <- factor(coord[[args$group_by]])
    p <- p + geom_point(aes(color = .data[[args$group_by]]), size = 3, alpha = 0.9) +
             stat_ellipse(aes(color = .data[[args$group_by]], group = .data[[args$group_by]]),
                          type = "t", linetype = 2, show.legend = FALSE) +
             labs(color = args$group_by)

    if (args$permanova == "auto" && nlevels(coord[[args$group_by]]) >= 2) {
        perm <- tryCatch(
            adonis2(as.matrix(dist_obj) ~ ., data = coord[, args$group_by, drop = FALSE], permutations = 999),
            error = function(e) NULL)
        if (!is.null(perm) && nrow(perm) >= 1) {
            r2  <- round(perm$R2[1], 3)
            pv  <- perm$`Pr(>F)`[1]
            lab <- paste0("PERMANOVA: R2 = ", r2, ", p = ", pv)
            p <- p + annotate("text", x = Inf, y = -Inf, label = lab, hjust = 1.05, vjust = -0.4, size = 3.5)
            writeLines(lab, file.path(args$output_dir, paste0("permanova_", args$distance, ".txt")))
        }
    }
}

ggsave(file.path(args$output_dir, paste0("pcoa_", args$distance, ".pdf")), p, width = 7, height = 6)
message("PCoA ordination complete.")
