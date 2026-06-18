#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors)
library(ggplot2)
library(dplyr)
library(patchwork)
library(ComplexHeatmap)
library(circlize) # For colorRamp2
library(shadowtext) # For annotating heatmaps
# library(igraph) # For network plots, not directly used in this version but useful
# library(qgraph) # For network plots, not directly used in this version but useful


# --- Argument Parsing ---
parser <- ArgumentParser(description='Perform correlation analysis between taxonomic features and metadata.')

parser$add_argument('--input_asv_counts', type='character', help='Path to the cleaned ASV count table (TSV).', required=TRUE)
parser$add_argument('--input_asv_taxonomy', type='character', help='Path to the ASV taxonomy table (TSV).', required=TRUE)
parser$add_argument('--input_metadata', type='character', help='Path to the sample metadata table (TSV).', required=TRUE)
parser$add_argument('--input_alpha_diversity', type='character', default=NULL, help='Path to the alpha diversity metrics table (TSV, optional).')
parser$add_argument('--output_dir', type='character', help='Output directory for correlation results and plots.', required=TRUE)
parser$add_argument('--level_to_analyze', type='character', default='Genus', help='Taxonomic level for correlation analysis (e.g., "Genus", "Phylum").')
parser$add_argument('--correlation_threshold', type='double', default=0.3, help='Minimum absolute correlation coefficient to display in heatmaps.')
parser$add_argument('--q_value_threshold', type='double', default=0.05, help='Q-value threshold for significance.')
parser$add_argument('--metadata_numeric_variables', type='character', default=NULL, help='Comma-separated list of numeric metadata column names (including alpha diversity) to correlate with taxonomic features.')
parser$add_argument('--replicate_variable', type='character', default=NULL, help='Name of the variable (metadata column) to merge replicates by (e.g., SubjectID). Samples with the same value will be aggregated (summed counts, averaged metadata).')
parser$add_argument('--fixed_effect_variable', type='character', default=NULL, help='Grouping variable (accepted for pipeline compatibility).')

args <- parser$parse_args()
if (!is.null(args$replicate_variable)) args$replicate_variable <- trimws(args$replicate_variable)

# Create output directory if it doesn't exist
if (!dir.exists(args$output_dir)) {
    dir.create(args$output_dir, recursive = TRUE)
}

# --- Utility function to read TSV data ---
read_tsv_data <- function(filepath, is_matrix=FALSE, has_rownames=TRUE, first_col_as_id=TRUE) {
    df <- fread(filepath, sep="\t", header=TRUE, data.table=FALSE, check.names = FALSE)
    
    if (has_rownames && first_col_as_id) {
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

message(paste("Loading ASV taxonomy from:", args$input_asv_taxonomy))
taxonomy_df <- read_tsv_data(args$input_asv_taxonomy, has_rownames=TRUE)

message(paste("Loading metadata from:", args$input_metadata))
metadata_df <- read_tsv_data(args$input_metadata, has_rownames=TRUE)

# Load alpha diversity if provided and merge into metadata
if (!is.null(args$input_alpha_diversity)) {
    message(paste("Loading alpha diversity from:", args$input_alpha_diversity))
    alpha_df <- read_tsv_data(args$input_alpha_diversity, has_rownames=FALSE, first_col_as_id=TRUE) # SampleID is the first col
    
    # Merge alpha_df into metadata_df by rownames (sample IDs)
    metadata_df <- merge(metadata_df, alpha_df, by = "row.names", all.x = TRUE)
    rownames(metadata_df) <- metadata_df$Row.names
    metadata_df$Row.names <- NULL
    message("Alpha diversity metrics merged into metadata.")
}


# --- Align samples and features ---
message("Aligning samples and features across input data...")
common_samples <- intersect(colnames(counts_matrix), rownames(metadata_df))
if (length(common_samples) == 0) {
    stop("No common samples between ASV counts table and metadata.")
}
counts_matrix <- counts_matrix[, common_samples, drop=FALSE]
metadata_df <- metadata_df[common_samples, , drop=FALSE]
message(paste("Retained", length(common_samples), "common samples."))

common_features <- intersect(rownames(counts_matrix), rownames(taxonomy_df))
if (length(common_features) == 0) {
    stop("No common features between ASV counts table and taxonomy table.")
}
counts_matrix <- counts_matrix[common_features, , drop=FALSE]
taxonomy_df <- taxonomy_df[common_features, , drop=FALSE]
message(paste("Retained", length(common_features), "common features."))


# --- Create TreeSummarizedExperiment Object ---
message("Creating TreeSummarizedExperiment object...")
tse <- TreeSummarizedExperiment(
    assays = SimpleList(counts = counts_matrix),
    rowData = S4Vectors::DataFrame(taxonomy_df, check.names = FALSE),
    colData = S4Vectors::DataFrame(metadata_df, check.names = FALSE)
)
message(paste("TreeSummarizedExperiment object created with dimensions:", dim(tse)[1], "features and", dim(tse)[2], "samples."))


# --- Aggregate Replicates if requested ---
if (!is.null(args$replicate_variable) && args$replicate_variable != "" && args$replicate_variable != "null") {
    message(paste("Merging replicates based on variable:", args$replicate_variable))
    
    # Check variable existence and handle sanitization
    if (!args$replicate_variable %in% names(colData(tse))) {
         safe_var <- make.names(args$replicate_variable)
         if (safe_var %in% names(colData(tse))) {
             message(paste0("Replicate variable '", args$replicate_variable, "' not found, but found sanitized version '", safe_var, "'. Using '", safe_var, "' instead."))
             args$replicate_variable <- safe_var
         } else {
             stop(paste("Replicate variable '", args$replicate_variable, "' not found in metadata."))
         }
    }
    
    # 1. Aggregating Counts (Summing)
    counts_mat <- assay(tse, "counts")
    
    # Use colData directly first to preserve names (avoid as.data.frame name mangling)
    col_data <- colData(tse)
    
    # Ensure metadata and counts are aligned by sample ID.
    common_samples_agg <- intersect(colnames(counts_mat), rownames(col_data))
    counts_mat <- counts_mat[, common_samples_agg, drop=FALSE]
    col_data <- col_data[common_samples_agg, , drop=FALSE]
    
    # Extract replicate vector from S4 DataFrame (preserves special characters like 'zone-tide')
    replicate_vec <- col_data[[args$replicate_variable]]
    
    # Create data.frame for dplyr operations, ensuring names are NOT checked/mangled
    meta_df <- as.data.frame(col_data, check.names = FALSE)
    
    # Check for NAs in replicate variable
    if(any(is.na(replicate_vec))) {
        warning("Replicate variable contains NAs. Samples with NA will be dropped in aggregation.")
        keep_idx <- !is.na(replicate_vec)
        
        # Apply filtering ensuring dimensions match
        counts_mat <- counts_mat[, keep_idx, drop=FALSE]
        meta_df <- meta_df[keep_idx, , drop=FALSE]
        replicate_vec <- replicate_vec[keep_idx]
    }
    
    # Debug: Print lengths if mismatch occurs
    if (length(replicate_vec) != ncol(counts_mat)) {
        stop(paste("Length mismatch between replicate vector (", length(replicate_vec), ") and number of samples in counts matrix (", ncol(counts_mat), "). Aggregation failed."))
    }

    # Sum counts across replicates (transpose -> rowsum -> transpose)
    # rowsum sums rows with same group. We want to sum columns with same group.
    message("Summing counts for replicates...")
    merged_counts_t <- rowsum(t(counts_mat), group = replicate_vec)
    merged_counts <- t(merged_counts_t)
    
    # 2. Aggregating Metadata (Averaging numeric, taking unique/first for others)
    message("Aggregating metadata for replicates...")
    
    # Use standard aggregation or ensuring column existence for dplyr
    # If the column name has special chars, we must be careful with dplyr symbols.
    
    # Ensure the replicate variable is in meta_df with the exact name
    if (!args$replicate_variable %in% names(meta_df)) {
        # This shouldn't happen if we extract from colData correctly, but let's be safe.
        # If as.data.frame mangled the name, we need to find it or re-add it.
        meta_df[[args$replicate_variable]] <- replicate_vec
    }

    collapsed_meta <- meta_df %>%
        group_by(.data[[args$replicate_variable]]) %>%
        summarise(across(everything(), ~ {
            val <- .
            if(is.numeric(val)) {
                mean(val, na.rm=TRUE) 
            } else {
                # For non-numeric, try to take unique value. 
                # If multiple unique values exist (conflicting metadata), take the first one and maybe warn?
                u_val <- unique(val)
                if(length(u_val) == 1) {
                    u_val 
                } else {
                    val[1] # Taking first as fallback
                }
            }
        })) %>%
        as.data.frame()
        
    # Set rownames to the replicate ID
    rownames(collapsed_meta) <- collapsed_meta[[args$replicate_variable]]
    
    # Align metadata rows with count columns
    # rowsum output order is sorted by group levels usually
    # subset columns of merged_counts to match collapsed_meta
    common_ids <- intersect(colnames(merged_counts), rownames(collapsed_meta))
    merged_counts <- merged_counts[, common_ids, drop=FALSE]
    collapsed_meta <- collapsed_meta[common_ids, , drop=FALSE]
    
    # Recreate TSE
    tse <- TreeSummarizedExperiment(
        assays = SimpleList(counts = merged_counts),
        rowData = rowData(tse, check.names = FALSE), # Taxonomy is unchanged
        colData = DataFrame(collapsed_meta, check.names = FALSE)
    )
    message(paste("Merged TSE has dimensions:", dim(tse)[1], "features and", dim(tse)[2], "merged samples."))
}


# --- Agglomerate to specified level ---
if (tolower(args$level_to_analyze) != "asv") {
    available_ranks <- colnames(rowData(tse))
    match_idx <- match(tolower(args$level_to_analyze), tolower(available_ranks))
    if (!is.na(match_idx)) args$level_to_analyze <- available_ranks[match_idx]
    message(paste("Agglomerating data to", args$level_to_analyze, "level for correlation analysis..."))
    if (!args$level_to_analyze %in% available_ranks) {
        stop(paste0("Taxonomic rank '", args$level_to_analyze, "' not found in taxonomy data. Available: ",
                    paste(available_ranks, collapse = ", ")))
    }
    tse_agglomerated <- agglomerateByRank(tse, rank = args$level_to_analyze)
    message(paste("Agglomerated TSE has dimensions:", dim(tse_agglomerated)[1], "features and", dim(tse_agglomerated)[2], "samples."))
} else {
    tse_agglomerated <- tse
    message("Performing correlation analysis at ASV level (no agglomeration).")
}

# Guard: CLR and feature-feature correlation require at least 2 features.
if (nrow(tse_agglomerated) < 2) {
    message(paste0("Only ", nrow(tse_agglomerated), " feature(s) remaining after agglomeration to '",
                   args$level_to_analyze, "' level. At least 2 are required for correlation analysis. Skipping."))
    message("Correlation analysis complete.")
    quit(status = 0)
}

# --- Apply CLR transformation and standardization ---
message("Applying CLR transformation and standardization for correlation analysis...")
tse_agglomerated <- transformAssay(tse_agglomerated, method = "clr", pseudocount = 1, name = "clr")
tse_agglomerated <- transformAssay(tse_agglomerated, assay.type = "clr", MARGIN = "rows", method = "standardize", name = "clr_z")


# --- Helper for robust result extraction ---
safe_extract <- function(res, field) {
    if (!is.null(res[[field]])) return(res[[field]])
    # Fallback names based on common package variations
    alt_names <- list(p = c("pval", "p_val", "p.value", "p.val"),
                      p_adj = c("padj", "p_adj_val", "q_val", "qvalue", "q.value"))
    if (field %in% names(alt_names)) {
        for (alt in alt_names[[field]]) {
            if (!is.null(res[[alt]])) return(res[[alt]])
        }
    }
    # Return matrix of NA if still not found
    if (!is.null(res$cor)) {
        return(matrix(NA, nrow=nrow(res$cor), ncol=ncol(res$cor)))
    }
    return(NULL)
}


# --- 1. Feature-Feature Correlation ---
message("Performing feature-feature correlation analysis...")
res_feat_feat <- tryCatch(
    getCrossAssociation(
        tse_agglomerated, tse_agglomerated,
        assay.type1 = "clr_z", assay.type2 = "clr_z",
        test.signif = TRUE, mode = "matrix"
    ),
    error = function(e) {
        message(paste("Feature-feature correlation failed:", e$message, "— skipping."))
        NULL
    }
)

if (is.null(res_feat_feat)) {
    message("Skipping feature-feature correlation output.")
} else {

# Robustly extract results
cor_matrix_feat_feat <- safe_extract(res_feat_feat, "cor")
p_adj_matrix_feat_feat <- safe_extract(res_feat_feat, "p_adj")

# Filter for plotting: Only keep significant correlations above threshold
to_keep_feat_feat <- abs(cor_matrix_feat_feat) >= args$correlation_threshold & !is.na(p_adj_matrix_feat_feat) & p_adj_matrix_feat_feat < args$q_value_threshold
cor_plot_matrix <- cor_matrix_feat_feat
cor_plot_matrix[!to_keep_feat_feat] <- NA # Set non-significant/low correlations to NA

if (all(is.na(cor_plot_matrix))) {
    message("No significant feature-feature correlations found above thresholds. Skipping heatmap.")
} else {
    # Replace NA with 0 for heatmap plotting if desired (or handle as white)
    cor_plot_matrix[is.na(cor_plot_matrix)] <- 0

    # Sort rows/columns for better visualization
    dist_cor_feat_feat <- as.dist(1 - abs(cor_plot_matrix))
    hclust_cor_feat_feat <- hclust(dist_cor_feat_feat, method = "average")
    
    # Heatmap for feature-feature correlation
    pdf(file.path(args$output_dir, paste0("heatmap_feature_feature_", tolower(args$level_to_analyze), ".pdf")), width = 10, height = 10)
    ht_feat_feat <- Heatmap(
        cor_plot_matrix,
        name = "Correlation",
        col = colorRamp2(c(-1, 0, 1), c("blue", "white", "red")),
        cluster_rows = hclust_cor_feat_feat,
        cluster_columns = hclust_cor_feat_feat,
        show_row_names = TRUE,
        show_column_names = TRUE,
        row_names_gp = gpar(fontsize = 6),
        column_names_gp = gpar(fontsize = 6),
        column_title = paste("Feature-Feature Correlation (", args$level_to_analyze, "level)"),
        layer_fun = function(j, i, x, y, width, height, fill) {
            # Vectorized annotation for performance
            p_vals <- p_adj_matrix_feat_feat[cbind(i, j)]
            is_sig <- !is.na(p_vals) & p_vals < args$q_value_threshold
            if (any(is_sig)) {
                grid.text("*", x[is_sig], y[is_sig], gp = gpar(fontsize = 10, col = "black"))
            }
        }
    )
    draw(ht_feat_feat, heatmap_legend_side = "bottom")
    dev.off()
    message(paste("Saved feature-feature correlation heatmap to:", file.path(args$output_dir, paste0("heatmap_feature_feature_", tolower(args$level_to_analyze), ".pdf"))))
    
    # Save feature-feature correlation results robustly
    p_vals_flat <- as.vector(safe_extract(res_feat_feat, "p"))
    padj_vals_flat <- as.vector(p_adj_matrix_feat_feat)
    
    results_feat_feat <- data.frame(
        Feature1 = rownames(cor_matrix_feat_feat)[row(cor_matrix_feat_feat)],
        Feature2 = colnames(cor_matrix_feat_feat)[col(cor_matrix_feat_feat)],
        Correlation = as.vector(cor_matrix_feat_feat)
    )
    
    # Only add P/Q values if lengths match (they should, but 0-row prevention is key)
    if (length(p_vals_flat) == nrow(results_feat_feat)) {
        results_feat_feat$P_value <- p_vals_flat
    } else {
        results_feat_feat$P_value <- NA
    }
    
    if (length(padj_vals_flat) == nrow(results_feat_feat)) {
        results_feat_feat$Q_value <- padj_vals_flat
    } else {
        results_feat_feat$Q_value <- NA
    }
    
    results_feat_feat <- results_feat_feat %>%
        filter(!is.na(Q_value) & Q_value < args$q_value_threshold, abs(Correlation) >= args$correlation_threshold) %>%
        arrange(Q_value)
    
    fwrite(results_feat_feat, file = file.path(args$output_dir, paste0("feature_feature_correlations_", tolower(args$level_to_analyze), ".tsv")), sep = "\t", quote = FALSE, row.names = FALSE)
    message(paste("Saved significant feature-feature correlations to:", file.path(args$output_dir, paste0("feature_feature_correlations_", tolower(args$level_to_analyze), ".tsv"))))
}

} # end is.null(res_feat_feat) check


# --- 2. Feature-Metadata Correlation ---
if (!is.null(args$metadata_numeric_variables)) {
    message("Performing feature-metadata correlation analysis...")
    metadata_vars_list <- unlist(strsplit(args$metadata_numeric_variables, ","))
    metadata_vars_list <- trimws(metadata_vars_list) # remove whitespace

    all_feat_meta_correlations <- data.frame()
    
    for (meta_var in metadata_vars_list) {
        meta_var <- trimws(meta_var)
        if (meta_var == "") next

        # Check variable existence and handle sanitization (hyphen/special chars to dots)
        actual_meta_var <- meta_var
        if (!actual_meta_var %in% names(colData(tse_agglomerated))) {
             safe_meta_var <- make.names(actual_meta_var)
             if (safe_meta_var %in% names(colData(tse_agglomerated))) {
                 message(paste0("Metadata variable '", actual_meta_var, "' not found, but found sanitized version '", safe_meta_var, "'. Using '", safe_meta_var, "' instead."))
                 actual_meta_var <- safe_meta_var
             } else {
                 warning(paste("Numeric metadata variable '", actual_meta_var, "' not found in metadata. Skipping."))
                 next
             }
        }

        # Ensure it's numeric
        if (!is.numeric(colData(tse_agglomerated)[[actual_meta_var]])) {
            warning(paste("Metadata variable '", actual_meta_var, "' is not numeric. Skipping."))
            next
        }

        message(paste("Correlating features with metadata variable:", actual_meta_var))
        
        # Check for sufficient non-NA observations and variance
        meta_vals <- as.numeric(colData(tse_agglomerated)[[actual_meta_var]])
        non_na_vals <- meta_vals[!is.na(meta_vals)]
        
        if (length(non_na_vals) < 3) {
            warning(paste("Metadata variable '", actual_meta_var, "' has too few non-NA observations (", length(non_na_vals), "). Skipping."))
            next
        }
        
        if (var(non_na_vals, na.rm = TRUE) == 0) {
            warning(paste("Metadata variable '", actual_meta_var, "' has zero variance (all values are the same). Skipping."))
            next
        }

        # Create a tiny SummarizedExperiment for the metadata variable
        meta_se <- SummarizedExperiment(
            assays = list(counts = matrix(meta_vals, nrow = 1, dimnames = list(actual_meta_var, colnames(tse_agglomerated)))),
            colData = colData(tse_agglomerated)
        )
        
        # Wrap correlation in tryCatch to handle "not enough finite observations" or other math errors
        res_feat_meta <- tryCatch({
            getCrossAssociation(
                tse_agglomerated, 
                experiment2 = meta_se,
                assay.type1 = "clr_z", 
                assay.type2 = "counts",
                test.signif = TRUE, 
                mode = "matrix"
            )
        }, error = function(e) {
            warning(paste("Error calculating correlation for", actual_meta_var, ":", e$message))
            return(NULL)
        })
        
        if (is.null(res_feat_meta)) next
        
        # Robustly extract results
        cor_matrix_feat_meta <- safe_extract(res_feat_meta, "cor")
        p_adj_matrix_feat_meta <- safe_extract(res_feat_meta, "p_adj")

        if (!is.null(cor_matrix_feat_meta)) {
            p_vals_meta_flat <- as.vector(safe_extract(res_feat_meta, "p"))
            padj_vals_meta_flat <- as.vector(p_adj_matrix_feat_meta)
            
            df_temp <- data.frame(
                Feature = rownames(cor_matrix_feat_meta),
                Metadata_Variable = meta_var, # Use original name for the table
                Correlation = as.vector(cor_matrix_feat_meta)
            )
            
            if (length(p_vals_meta_flat) == nrow(df_temp)) df_temp$P_value <- p_vals_meta_flat else df_temp$P_value <- NA
            if (length(padj_vals_meta_flat) == nrow(df_temp)) df_temp$Q_value <- padj_vals_meta_flat else df_temp$Q_value <- NA
            
            df_temp <- df_temp %>%
                filter(!is.na(Q_value) & Q_value < args$q_value_threshold, abs(Correlation) >= args$correlation_threshold) %>%
                arrange(Q_value)
            
            if (nrow(df_temp) > 0) {
                all_feat_meta_correlations <- rbind(all_feat_meta_correlations, df_temp)

                # Heatmap for feature-metadata correlation
                # Filter matrix to only show significant correlations
                sig_cor_matrix <- cor_matrix_feat_meta
                sig_cor_matrix[abs(sig_cor_matrix) < args$correlation_threshold | is.na(p_adj_matrix_feat_meta) | p_adj_matrix_feat_meta >= args$q_value_threshold] <- NA

                if (all(is.na(sig_cor_matrix))) {
                    message(paste("No significant feature-metadata correlations found for", actual_meta_var, ". Skipping heatmap."))
                } else {
                    # Order rows by correlation value for current actual_meta_var
                    ordered_features <- rownames(sig_cor_matrix)[order(sig_cor_matrix[,1], decreasing = TRUE)]
                    sig_cor_matrix <- sig_cor_matrix[ordered_features, , drop=FALSE]
                    p_adj_for_plot <- p_adj_matrix_feat_meta[ordered_features, , drop=FALSE]

                    pdf(file.path(args$output_dir, paste0("heatmap_feature_", actual_meta_var, "_", tolower(args$level_to_analyze), ".pdf")), width = 5, height = 0.5 * nrow(sig_cor_matrix) + 2) # Dynamic height
                    if (nrow(sig_cor_matrix) == 0) {
                      # Handle case with no significant correlations
                      plot(NA, xlim=c(0,1), ylim=c(0,1), type="n", ann=FALSE, axes=FALSE)
                      text(0.5, 0.5, paste("No significant correlations for", actual_meta_var))
                    } else {
                      ht_feat_meta <- Heatmap(
                          sig_cor_matrix,
                          name = "Correlation",
                          col = colorRamp2(c(-1, 0, 1), c("blue", "white", "red")),
                          cluster_rows = FALSE, # Already ordered
                          cluster_columns = FALSE,
                          show_row_names = TRUE,
                          show_column_names = TRUE,
                          row_names_gp = gpar(fontsize = 8),
                          column_names_gp = gpar(fontsize = 8),
                          column_title = paste("Feature-", actual_meta_var, " Correlation (", args$level_to_analyze, "level)", sep=""),
                          layer_fun = function(j, i, x, y, width, height, fill) {
                              # Vectorized annotation
                              curr_p <- p_adj_for_plot[cbind(i, j)]
                              is_sig <- !is.na(curr_p) & curr_p < args$q_value_threshold
                              if (any(is_sig)) {
                                  grid.text("*", x[is_sig], y[is_sig], gp = gpar(fontsize = 10, col = "black"))
                              }
                          }
                      )
                      draw(ht_feat_meta, heatmap_legend_side = "bottom")
                    }
                    dev.off()
                    message(paste("Saved feature-", actual_meta_var, " correlation heatmap to:", file.path(args$output_dir, paste0("heatmap_feature_", actual_meta_var, "_", tolower(args$level_to_analyze), ".pdf"))))
                }
            }
        }
    }
    
    if (nrow(all_feat_meta_correlations) > 0) {
        fwrite(all_feat_meta_correlations, file = file.path(args$output_dir, paste0("feature_metadata_correlations_", tolower(args$level_to_analyze), ".tsv")), sep = "\t", quote = FALSE, row.names = FALSE)
        message(paste("Saved significant feature-metadata correlations to:", file.path(args$output_dir, paste0("feature_metadata_correlations_", tolower(args$level_to_analyze), ".tsv"))))
    } else {
        message("No significant feature-metadata correlations found above thresholds.")
    }

} else {
    message("No numeric metadata variables provided for feature-metadata correlation.")
}

message("Correlation analysis complete.")