#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors)
library(ggplot2)
library(patchwork)
library(scater) # For plotReducedDim
library(bluster) # For HclustParam
# miaViz not needed - using ggplot2 for bar plots and scater for PCoA


# --- Argument Parsing ---
parser <- ArgumentParser(description='Perform community typing (hierarchical clustering) and visualize results.')

parser$add_argument('--input_asv_counts', type='character', help='Path to the cleaned ASV count table (TSV).', required=TRUE)
parser$add_argument('--input_metadata', type='character', help='Path to the sample metadata table (TSV).', required=TRUE)
parser$add_argument('--output_dir', type='character', help='Output directory for community typing results and plots.', required=TRUE)
parser$add_argument('--distance_metric', type='character', default='bray', help='Dissimilarity metric for clustering (e.g., "bray", "euclidean").')
parser$add_argument('--clustering_method', type='character', default='ward.D2', help='Hierarchical clustering linkage method (e.g., "ward.D2", "average").')
parser$add_argument('--num_clusters', type='integer', default=4, help='Number of clusters (k) to cut the dendrogram into.')

args <- parser$parse_args()

# Create output directory if it doesn't exist
if (!dir.exists(args$output_dir)) {
    dir.create(args$output_dir, recursive = TRUE)
}

# --- Utility function to read TSV data ---
read_tsv_data <- function(filepath, is_matrix=FALSE, has_rownames=TRUE) {
    df <- fread(filepath, sep="	", header=TRUE, data.table=FALSE)
    
    if (has_rownames) {
        row_id_col_name <- names(df)[1]
        if (is.null(row_id_col_name) || row_id_col_name == "" || row_id_col_name == "V1") {
            rownames(df) <- df[[1]]
            df <- df[, -1, drop=FALSE]
        } else {
            rownames(df) <- df[[row_id_col_name]]
            df <- df[, -which(names(df) == row_id_col_name), drop=FALSE]
        }
    }

    if (is_matrix) {
        matrix_data <- as.matrix(df)
        mode(matrix_data) <- "numeric"
        return(matrix_data)
    } else {
        return(df)
    }
}


# --- Load Data ---
message(paste("Loading ASV counts from:", args$input_asv_counts))
counts_matrix <- read_tsv_data(args$input_asv_counts, is_matrix=TRUE)

message(paste("Loading metadata from:", args$input_metadata))
metadata_df <- read_tsv_data(args$input_metadata, has_rownames=TRUE)


# --- Align samples ---
common_samples <- intersect(colnames(counts_matrix), rownames(metadata_df))
if (length(common_samples) == 0) {
    stop("No common samples between ASV counts table and metadata.")
}
counts_matrix <- counts_matrix[, common_samples, drop=FALSE]
metadata_df <- metadata_df[common_samples, , drop=FALSE]
message(paste("Retained", length(common_samples), "common samples."))


# --- Create TreeSummarizedExperiment Object ---
message("Creating TreeSummarizedExperiment object...")
tse <- TreeSummarizedExperiment(
    assays = SimpleList(counts = counts_matrix),
    colData = S4Vectors::DataFrame(metadata_df)
)
message(paste("TreeSummarizedExperiment object created with dimensions:", dim(tse)[1], "features and", dim(tse)[2], "samples."))


# --- Remove zero-count samples before any transformation ---
zero_count_samples <- colnames(tse)[colSums(assay(tse, "counts")) == 0]
if (length(zero_count_samples) > 0) {
    message(paste("Removing", length(zero_count_samples), "sample(s) with zero total counts:",
                  paste(zero_count_samples, collapse = ", ")))
    tse <- tse[, colSums(assay(tse, "counts")) > 0]
}
message(paste("Samples remaining after filtering zero-count samples:", ncol(tse)))

# --- Transform to relative abundance for clustering ---
message("Transforming counts to relative abundance...")
tse <- transformAssay(tse, method = "relabundance", name = "relabundance")


# --- Perform Hierarchical Clustering ---
message(paste("Performing hierarchical clustering with", args$distance_metric, "distance and", args$clustering_method, "linkage..."))
tse <- addCluster(
    tse,
    assay.type = "relabundance",
    by = "cols", # Cluster samples
    HclustParam(
        dist.fun = getDissimilarity, 
        metric = args$distance_metric,
        method = args$clustering_method,
        cut.params = list(k = args$num_clusters) # Use cut.params instead of deprecated full parameter
    ),
    clust.col = "hclust_clusters" # Name of the column in colData to store cluster assignments
)
message(paste("Clustering complete. Identified", length(unique(colData(tse)$hclust_clusters)), "clusters."))


# --- Save Cluster Assignments ---
cluster_output_file <- file.path(args$output_dir, "sample_clusters.tsv")
message(paste("Saving sample cluster assignments to:", cluster_output_file))
sample_clusters_df <- data.frame(
    SampleID = rownames(colData(tse)),
    Cluster = colData(tse)$hclust_clusters
)
fwrite(sample_clusters_df, file = cluster_output_file, sep = "	", quote = FALSE, row.names = FALSE)


# --- Visualize Cluster Distribution (Bar Plot) ---
message("Generating cluster distribution bar plot...")
barplot_data <- S4Vectors::as.data.frame(colData(tse))
barplot_data$Cluster <- as.factor(barplot_data$hclust_clusters) # Ensure cluster is a factor for plotting
p_barplot <- ggplot(barplot_data, aes(x = Cluster, fill = Cluster)) +
    geom_bar() +
    labs(title = "Distribution of Samples Across Clusters",
         x = "Cluster",
         y = "Number of Samples") +
    theme_minimal()

# --- Visualize PCoA colored by clusters ---
message("Performing PCoA on Bray-Curtis for visualization...")
# Calculate dissimilarity matrix first
tse <- addDissimilarity(tse, assay.type = "relabundance", method = args$distance_metric, name = "cluster_dist")

# Perform PCoA using scater::calculateMDS
dist_obj <- metadata(tse)[["cluster_dist"]]
reducedDim(tse, "PCoA_cluster") <- scater::calculateMDS(dist_obj, ncomponents = 2)

message("Generating PCoA plot colored by clusters...")
p_pcoa <- plotReducedDim(
    tse,
    "PCoA_cluster",
    colour_by = "hclust_clusters",
    shape_by = "hclust_clusters",  # Add shapes for better distinction
    point_size = 3
) +
    labs(title = paste("PCoA colored by Hierarchical Clusters (k=", args$num_clusters, ")")) +
    scale_color_brewer(palette = "Set1") +  # Use vibrant colors
    scale_shape_manual(values = c(15, 16, 17, 18, 19, 8, 3, 4, 7, 9, 10, 11, 12, 13, 14)) +
    theme_minimal() +
    theme(
        legend.position = "bottom",
        legend.title = element_text(face = "bold"),
        plot.title = element_text(face = "bold", hjust = 0.5)
    )

# Combine plots into a single PDF
output_plot_file <- file.path(args$output_dir, "community_typing_plots.pdf")
message(paste("Saving community typing plots to:", output_plot_file))

combined_plots <- patchwork::wrap_plots(p_barplot, p_pcoa, ncol = 2)
ggsave(output_plot_file, plot = combined_plots, width = 14, height = 7)

saveRDS(tse, file.path(args$output_dir, "community_typing.rds"))
message("Community typing analysis and plotting complete.")