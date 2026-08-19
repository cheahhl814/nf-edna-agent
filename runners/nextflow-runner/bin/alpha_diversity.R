#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors)
library(ape)
library(phytools) # For midpoint.root (though no longer used here, it was from user's tree script)
library(ggplot2)
library(ggpubr)
library(patchwork)
library(scater) # For plotColData
library(rstatix)
library(magrittr)


# --- Argument Parsing ---
parser <- ArgumentParser(description='Calculate and plot alpha diversity metrics.')

parser$add_argument('--input_asv_counts', type='character', help='Path to the cleaned ASV count table (TSV).', required=TRUE)
parser$add_argument('--input_metadata', type='character', help='Path to the sample metadata table (TSV).', required=TRUE)
parser$add_argument('--input_tree', type='character', help='Path to the rooted phylogenetic tree file (Newick).', required=TRUE)
parser$add_argument('--output_dir', type='character', help='Output directory for alpha diversity results and plots.', required=TRUE)
parser$add_argument('--grouping_variable', type='character', help='Name of the column in metadata to use for grouping/plotting (e.g., "zone-tide").', required=TRUE)


args <- parser$parse_args()
args$grouping_variable <- trimws(args$grouping_variable)

# Create output directory if it doesn't exist
if (!dir.exists(args$output_dir)) {
    dir.create(args$output_dir, recursive = TRUE)
}

# --- Utility function to read TSV data ---
read_tsv_data <- function(filepath, is_matrix=FALSE, has_rownames=TRUE) {
    df <- fread(filepath, sep="	", header=TRUE, data.table=FALSE, check.names = FALSE)
    
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
metadata_df <- read_tsv_data(args$input_metadata, has_rownames=TRUE) # Assuming metadata has sample IDs as rownames

message(paste("Loading rooted phylogenetic tree from:", args$input_tree))
phylo_tree <- read.tree(args$input_tree)


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
    colData = S4Vectors::DataFrame(metadata_df, check.names = FALSE),
    rowTree = phylo_tree # Add the rooted tree here
)
message(paste("TreeSummarizedExperiment object created with dimensions:", dim(tse)[1], "features and", dim(tse)[2], "samples."))
message(paste("Available metadata columns:", paste(names(colData(tse)), collapse=", ")))


# --- Calculate Alpha Diversity Metrics ---
message("Calculating alpha diversity metrics...")
# Define metrics to calculate
alpha_metrics <- c("observed", "shannon", "faith") # faith requires a tree

# Add alpha diversity to colData
tse <- addAlpha(tse, assay.type = "counts", index = alpha_metrics)
message("Alpha diversity metrics calculated and added to colData.")

# Ensure the grouping variable is a factor
if (!args$grouping_variable %in% names(colData(tse))) {
    # Check if it was converted to a 'safe' name (e.g. with dots)
    safe_name <- make.names(args$grouping_variable)
    if (safe_name %in% names(colData(tse))) {
        message(paste0("Using '", safe_name, "' as the grouping variable (original: '", args$grouping_variable, "')"))
        args$grouping_variable <- safe_name
    } else {
        stop(paste("Grouping variable '", args$grouping_variable, "' not found in metadata. Available: ", paste(names(colData(tse)), collapse=", ")))
    }
}
colData(tse)[[args$grouping_variable]] <- as.factor(colData(tse)[[args$grouping_variable]])


# --- Save Alpha Diversity Results ---
alpha_output_file <- file.path(args$output_dir, "alpha_diversity_metrics.tsv")
message(paste("Saving alpha diversity metrics to:", alpha_output_file))
# Extract only the alpha diversity columns from colData
alpha_df_to_save <- S4Vectors::as.data.frame(colData(tse))[, alpha_metrics, drop=FALSE]
fwrite(data.frame(SampleID = rownames(alpha_df_to_save), alpha_df_to_save), file = alpha_output_file, sep = "	", quote = FALSE, row.names = FALSE)


# --- Visualize Alpha Diversity ---
message("Generating alpha diversity plots...")
plot_list <- list()

for (metric in alpha_metrics) {
    message(paste("Plotting", metric, "..."))
    
    # Create a temporary plotting dataframe with 'safe' column names for rstatix/dplyr
    # This prevents hyphens from being interpreted as minus signs in formulas
    plot_df <- S4Vectors::as.data.frame(colData(tse))
    safe_metric <- make.names(metric)
    safe_group <- make.names(args$grouping_variable)
    
    colnames(plot_df)[colnames(plot_df) == metric] <- safe_metric
    colnames(plot_df)[colnames(plot_df) == args$grouping_variable] <- safe_group

    # Calculate pairwise Wilcoxon tests for p-value annotations
    # We use rstatix::wilcox_test for better compatibility with add_xy_position.
    # Wrapped in tryCatch: with only 2 replicates per group the exact Wilcoxon
    # computation can fail; in that case we skip significance annotations.
    stat_test <- tryCatch(
        plot_df %>%
            wilcox_test(as.formula(paste(safe_metric, "~", safe_group))) %>%
            adjust_pvalue(method = "fdr") %>%
            add_significance(),
        error = function(e) {
            message(paste0("Wilcoxon test failed for '", metric, "': ", conditionMessage(e),
                           " — skipping significance annotations."))
            data.frame()
        }
    )
    
    # --- Unified Plotting using sanitized plot_df ---
    # This avoids all issues with hyphens/special chars in column names
    # and ensures consistency between the data frame and the plot.
    
    # Calculate y-positions for significance bars if needed
    if (nrow(stat_test) > 0) {
        max_y <- max(plot_df[[safe_metric]], na.rm = TRUE)
        min_y <- min(plot_df[[safe_metric]], na.rm = TRUE)
        y_pos_increment <- (max_y - min_y) * 0.1 
        
        stat_test <- stat_test %>%
            add_xy_position(
                formula = as.formula(paste(safe_metric, "~", safe_group)), 
                data = plot_df, 
                fun = "max", 
                step.increase = y_pos_increment
            )
    }

    # Build the base plot using the SAFE data frame and SAFE names
    p <- ggplot(plot_df, aes(x = .data[[safe_group]], y = .data[[safe_metric]])) +
        geom_violin(aes(fill = .data[[safe_group]]), alpha = 0.5) +
        geom_boxplot(width = 0.1, fill = "white") +
        labs(
            title = paste(metric, "by", args$grouping_variable),
            x = args$grouping_variable,
            y = metric,
            fill = args$grouping_variable
        ) +
        theme_minimal() +
        theme(axis.text.x = element_text(angle = 45, hjust = 1))

    # Add significance bars if applicable
    if (nrow(stat_test) > 0) {
        p <- p + stat_pvalue_manual(stat_test, label = "p.adj.signif", hide.ns = TRUE, tip.length = 0.01)
    }
    
    plot_list[[metric]] <- p
}

# Save each plot to a separate PDF
message("Saving separate alpha diversity plots...")
for (metric in names(plot_list)) {
    output_plot_file <- file.path(args$output_dir, paste0("alpha_diversity_", metric, ".pdf"))
    message(paste("Saving", metric, "plot to:", output_plot_file))
    ggsave(output_plot_file, plot = plot_list[[metric]], width = 6, height = 6)
}


message("Alpha diversity analysis and plotting complete.")