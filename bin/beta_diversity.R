#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors)
library(ape)
library(ggplot2)
library(patchwork)
library(scater)
library(ComplexHeatmap)
library(circlize)  # Provides colorRamp2 for heatmap color scales
library(vegan) # Needed for getDissimilarity methods sometimes

# --- Argument Parsing ---
parser <- ArgumentParser(description='Calculate and plot beta diversity analyses.')

parser$add_argument('--input_asv_counts', type='character', help='Path to the cleaned ASV count table (TSV).', required=TRUE)
parser$add_argument('--input_metadata', type='character', help='Path to the sample metadata table (TSV).', required=TRUE)
parser$add_argument('--input_tree', type='character', help='Path to the rooted phylogenetic tree file (Newick).', required=TRUE)
parser$add_argument('--output_dir', type='character', help='Output directory for beta diversity results and plots.', required=TRUE)
parser$add_argument('--grouping_variable', type='character', help='Name of the column in metadata to use for grouping/plotting (e.g., "zone-tide").', required=TRUE)
parser$add_argument('--input_asv_taxonomy', type='character', default=NULL, help='Path to ASV taxonomy table (TSV). Accepted but not used in beta diversity calculations.')
parser$add_argument('--distance_metric', type='character', default='bray', help='Primary distance metric (accepted for pipeline compatibility; all four metrics are always computed).')

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
metadata_df <- read_tsv_data(args$input_metadata, has_rownames=TRUE)

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

# Ensure grouping variable is factor
if (!args$grouping_variable %in% names(colData(tse))) {
    stop(paste("Grouping variable '", args$grouping_variable, "' not found in metadata."))
}
colData(tse)[[args$grouping_variable]] <- as.factor(colData(tse)[[args$grouping_variable]])


# --- Remove zero-count samples before any transformation ---
zero_count_samples <- colnames(tse)[colSums(assay(tse, "counts")) == 0]
if (length(zero_count_samples) > 0) {
    message(paste("Removing", length(zero_count_samples), "sample(s) with zero total counts:",
                  paste(zero_count_samples, collapse = ", ")))
    tse <- tse[, colSums(assay(tse, "counts")) > 0]
}
message(paste("Samples remaining after filtering zero-count samples:", ncol(tse)))

# --- Transform data for various beta diversity metrics ---
message("Applying necessary data transformations...")
# Relative abundance for Bray-Curtis
tse <- transformAssay(tse, method = "relabundance", name = "relabundance")
# Presence/Absence for Jaccard
tse <- transformAssay(tse, method = "pa", name = "pa")
# CLR for Aitchison Distance (Euclidean on CLR)
tse <- transformAssay(tse, assay.type = "counts", method = "clr", pseudocount = 1, name = "clr")


# --- Calculate Beta Diversity Dissimilarity Matrices ---
message("Calculating beta diversity dissimilarity matrices...")

# Bray-Curtis
tse <- addDissimilarity(tse, assay.type = "relabundance", method = "bray", name = "bray_curtis")
message("Bray-Curtis dissimilarity calculated.")

# Jaccard
tse <- addDissimilarity(tse, assay.type = "pa", method = "jaccard", name = "jaccard")
message("Jaccard dissimilarity calculated.")

# UniFrac (requires rbiom::unifrac; skipped gracefully if unavailable)
unifrac_ok <- tryCatch({
    tse <- addDissimilarity(tse, assay.type = "counts", method = "unifrac", name = "unifrac", tree = rowTree(tse))
    message("UniFrac dissimilarity calculated.")
    TRUE
}, error = function(e) {
    message("UniFrac skipped (rbiom::unifrac unavailable): ", e$message)
    FALSE
})

# Aitchison Distance (Euclidean on CLR)
tse <- addDissimilarity(tse, assay.type = "clr", method = "euclidean", name = "aitchison")
message("Aitchison dissimilarity calculated.")


# --- Perform Ordination (PCoA/MDS) ---
# --- Perform Ordination (PCoA/MDS) ---
message("Performing PCoA/MDS ordination for visualization...")

# Helper to run MDS using pre-calculated distances in metadata (from addDissimilarity)
# or calculate on the fly if needed. 
# Robust approach: Calculate dist, check dimensions, run MDS, assign.

run_pcoa_robust <- function(tse, metric_name, dist_name) {
    # Check if distance matrix exists in metadata (added by addDissimilarity)
    # addDissimilarity stores output in metadata(tse)[[name]] usually
    # Use tryCatch to fall back to 'getDissimilarity' if not found
    
    dist_obj <- tryCatch({
        # Attempt to retrieve from metadata using likely names
        meta_dist <- metadata(tse)[[dist_name]]
        if(is.null(meta_dist)) stop("Not in metadata")
        meta_dist
    }, error = function(e) {
        # Fallback: calculate fresh
        message(paste("Recalculating distance for", metric_name))
        getDissimilarity(tse, name = metric_name) # Uses internal defaults or we'd need more args
    })
    
    # Verify dimensions
    if (attr(dist_obj, "Size") != ncol(tse)) {
        # If mismatch (e.g. unifrac pruning), we must align tse
        # This is complex inside a helper without side effects.
        # So we assume the upstream filter caught zeros.
        # If unifrac pruned tips, it might still drop samples.
        warning(paste("Dimension mismatch for", metric_name, "- skipping PCoA assignment to TSE."))
        return(tse)
    }

    # Run MDS
    mds_res <- scater::calculateMDS(dist_obj, ncomponents = 2)
    
    # Assign to reducedDim
    reducedDim(tse, dist_name) <- mds_res
    return(tse)
}

# We already ran addDissimilarity which adds to metadata(tse)
# keys used: "bray_curtis", "jaccard", "unifrac", "aitchison"

# Run PCoA using these distances
# Note: scater::calculateMDS takes a distance object directly
# We perform this manually to avoid runMDS dispatch issues and deprecation warnings
dist_bray <- metadata(tse)[["bray_curtis"]]
reducedDim(tse, "PCoA_bray") <- scater::calculateMDS(dist_bray, ncomponents = 2)

dist_jaccard <- metadata(tse)[["jaccard"]]
reducedDim(tse, "PCoA_jaccard") <- scater::calculateMDS(dist_jaccard, ncomponents = 2)

if (unifrac_ok) {
    dist_unifrac <- metadata(tse)[["unifrac"]]
    reducedDim(tse, "PCoA_unifrac") <- scater::calculateMDS(dist_unifrac, ncomponents = 2)
}

dist_aitchison <- metadata(tse)[["aitchison"]]
reducedDim(tse, "PCoA_aitchison") <- scater::calculateMDS(dist_aitchison, ncomponents = 2)


# --- Visualize Ordination Plots ---
message("Generating PCoA plots...")
pcoa_plots <- list()

# Helper to get explained variance (eigenvalues) for plot labels
get_explained_variance <- function(tse_obj, reduced_dim_name) {
  # scater::runMDS stores eigenvalues in the 'eig' attribute of the reducedDim matrix
  # or sometimes checking the 'percentVar' attribute if available
  rd <- reducedDim(tse_obj, reduced_dim_name)
  e <- attr(rd, "eig")
  
  if (!is.null(e)) {
      rel_eig <- e / sum(e[e > 0])
      pc1_var <- round(100 * rel_eig[[1]], 1)
      pc2_var <- round(100 * rel_eig[[2]], 1)
  } else {
      # Fallback or different storage (e.g. sometimes percentVar is calculated)
      # For now, if we can't find it, return NA
      pc1_var <- "NA"
      pc2_var <- "NA"
  }
  return(list(pc1 = pc1_var, pc2 = pc2_var))
}


# Plotting function for PCoA
plot_pcoa <- function(tse_obj, reduced_dim_name, group_var, title) {
  pc_vars <- get_explained_variance(tse_obj, reduced_dim_name)
  plotReducedDim(
    tse_obj,
    reduced_dim_name,
    colour_by = group_var,
    shape_by = group_var,  # Use shapes in addition to colors for better distinction
    point_size = 3  # Slightly larger points to make shapes more visible
    # Removed text_by parameter to avoid cluttering the plot with sample labels
  ) +
    labs(
      x = paste0("PCoA 1 (", pc_vars$pc1, "%)"),
      y = paste0("PCoA 2 (", pc_vars$pc2, "%)"),
      title = title
    ) +
    scale_color_brewer(palette = "Set1") +  # Use vibrant, high-contrast colors
    scale_shape_manual(values = c(15, 16, 17, 18, 19, 8, 3, 4, 7, 9, 10, 11, 12, 13, 14)) +  # Diverse, distinguishable shapes
    guides(
      color = guide_legend(title = group_var, override.aes = list(size = 4)),
      shape = guide_legend(title = group_var, override.aes = list(size = 4))
    ) +
    theme_minimal() +
    theme(
      legend.position = "bottom",
      legend.title = element_text(face = "bold", size = 11),
      legend.text = element_text(size = 10),
      plot.title = element_text(face = "bold", size = 14, hjust = 0.5),
      legend.box = "vertical"  # Stack color and shape legends vertically if needed
    )
}

pcoa_plots[["bray_curtis"]] <- plot_pcoa(tse, "PCoA_bray", args$grouping_variable, "PCoA (Bray-Curtis)")
pcoa_plots[["jaccard"]] <- plot_pcoa(tse, "PCoA_jaccard", args$grouping_variable, "PCoA (Jaccard)")
if (unifrac_ok) pcoa_plots[["unifrac"]] <- plot_pcoa(tse, "PCoA_unifrac", args$grouping_variable, "PCoA (UniFrac)")
pcoa_plots[["aitchison"]] <- plot_pcoa(tse, "PCoA_aitchison", args$grouping_variable, "PCoA (Aitchison)")


# --- Statistical Analysis (PERMANOVA) ---
message("Performing PERMANOVA statistical tests...")
permanova_results <- list()

run_permanova <- function(tse_obj, dist_name, group_var) {
  # Retrieve pre-calculated distance matrix
  dist_obj <- metadata(tse_obj)[[dist_name]]
  
  if (is.null(dist_obj)) {
    warning(paste("Distance matrix", dist_name, "not found in metadata. Skipping PERMANOVA."))
    return(NULL)
  }
  
  # Check dimensions
  # Check dimensions
  # Some distance objects might not have the "Size" attribute directly accessible via attr()
  # Try to determine size robustly
  dist_size <- attr(dist_obj, "Size")
  
  if (is.null(dist_size)) {
      # Try coercing to matrix to find dimension
      # Initialize likely dimensions to NULL
      dim_check <- try({
          dist_mat <- as.matrix(dist_obj)
          nrow(dist_mat)
      }, silent = TRUE)
      
      if (!inherits(dim_check, "try-error") && is.numeric(dim_check)) {
          dist_size <- dim_check
      }
  }
  
  if (is.null(dist_size)) {
       warning(paste("Could not determine size of distance matrix", dist_name, ". Skipping dimension check."))
  } else if (dist_size != ncol(tse_obj)) {
    warning(paste("Dimension mismatch for", dist_name, "in PERMANOVA. Dist size:", dist_size, "TSE samples:", ncol(tse_obj), ". Skipping."))
    return(NULL)
  }

  # Build formula with safe variable names
  # adonis2 handles dataframe input in 'data' argument
  # We need to ensure the group_var is correctly referenced
  
  # Create a data frame for the model
  # Use check.names = FALSE to preserve hyphens in column names (e.g. "zone-tide")
  meta_df <- as.data.frame(colData(tse_obj), check.names = FALSE)
  
  if (!group_var %in% names(meta_df)) {
      # Fallback: check if it was sanitized
      safe_var <- make.names(group_var)
      if (safe_var %in% names(meta_df)) {
          message(paste("Grouping variable renamed to", safe_var, "in PERMANOVA dataframe."))
          group_var <- safe_var
      } else {
          warning(paste("Grouping variable", group_var, "not found in metadata for PERMANOVA. Skipping."))
          return(NULL)
      }
  }
  
  # Ensure the grouping variable is a factor
  meta_df[[group_var]] <- as.factor(meta_df[[group_var]])
  
  # Safe formula construction
  # We use backticks to handle special characters in column names
  formula_str <- paste0("dist_obj ~ `", group_var, "`")
  f <- as.formula(formula_str)
  
  message(paste("Running PERMANOVA (adonis2) for", dist_name, "..."))
  
  # Run PERMANOVA
  # permutations=999 is standard
  res <- tryCatch({
    vegan::adonis2(f, data = meta_df, permutations = 999)
  }, error = function(e) {
    message(paste("PERMANOVA failed for", dist_name, ":", e$message))
    return(NULL)
  })
  
  # Return in a structure compatible with downstream saving code
  # The downstream code expects: res$permanova$aov.tab
  if (!is.null(res)) {
      return(list(permanova = list(aov.tab = res)))
  } else {
      return(NULL)
  }
}

permanova_results[["bray_curtis"]] <- run_permanova(tse, "bray_curtis", args$grouping_variable)
permanova_results[["jaccard"]] <- run_permanova(tse, "jaccard", args$grouping_variable)
permanova_results[["unifrac"]] <- run_permanova(tse, "unifrac", args$grouping_variable)
permanova_results[["aitchison"]] <- run_permanova(tse, "aitchison", args$grouping_variable)


# Save PERMANOVA results
permanova_output_file <- file.path(args$output_dir, "permanova_results.tsv")
message(paste("Saving PERMANOVA results to:", permanova_output_file))
# Combine all permanova results into a single data frame for saving
all_permanova_df <- data.frame()
for (metric_name in names(permanova_results)) {
  if (!is.null(permanova_results[[metric_name]]$permanova)) {
    df_temp <- as.data.frame(permanova_results[[metric_name]]$permanova$aov.tab)
    df_temp$Metric <- metric_name
    df_temp$Term <- rownames(df_temp)
    all_permanova_df <- rbind(all_permanova_df, df_temp)
  }
}
fwrite(all_permanova_df, file = permanova_output_file, sep = "	", quote = FALSE, row.names = FALSE)


# --- Visualize Dissimilarity Matrix Heatmaps ---
message("Generating dissimilarity matrix heatmaps...")
heatmap_plots <- list()

plot_dissimilarity_heatmap <- function(tse_obj, metric_name, group_var, title) {
  # Retrieve pre-calculated distance matrix from metadata
  dist_matrix <- metadata(tse_obj)[[metric_name]]
  
  if (is.null(dist_matrix)) {
      warning(paste("Distance matrix", metric_name, "not found in metadata. Skipping heatmap."))
      return(NULL)
  }
  
  # Create annotation for samples
  if (!is.null(group_var) && group_var %in% names(colData(tse_obj))) {
    # Get unique groups
    groups <- unique(colData(tse_obj)[[group_var]])
    
    # Create a simple color palette
    n_groups <- length(groups)
    group_colors <- setNames(
      rainbow(n_groups),
      as.character(groups)
    )
    
    col_anno <- HeatmapAnnotation(
      Group = colData(tse_obj)[[group_var]],
      col = list(Group = group_colors)
    )
  } else {
    col_anno <- NULL
  }
  
  # Ensure the distance matrix is actually a matrix
  if (inherits(dist_matrix, "dist")) {
      dist_matrix <- as.matrix(dist_matrix)
  }

  ht <- Heatmap(
    dist_matrix,
    name = title,
    col = colorRamp2(c(0, 0.5, 1), c("blue", "white", "red")), # Example color scale
    cluster_rows = TRUE,
    cluster_columns = TRUE,
    show_row_names = FALSE,
    show_column_names = FALSE,
    top_annotation = col_anno,
    column_title = title,
    row_title = NULL # No row title needed for square matrix
  )
  return(ht)
}

# Heatmap for UniFrac and Bray-Curtis
heatmap_plots[["unifrac"]] <- plot_dissimilarity_heatmap(tse, "unifrac", args$grouping_variable, "UniFrac Dissimilarity")
heatmap_plots[["bray_curtis"]] <- plot_dissimilarity_heatmap(tse, "bray_curtis", args$grouping_variable, "Bray-Curtis Dissimilarity")


# --- Save Plots ---
message("Saving beta diversity plots to separate files...")

# Save each PCoA plot to a separate PDF
for (metric_name in names(pcoa_plots)) {
  pcoa_file <- file.path(args$output_dir, paste0("pcoa_", metric_name, ".pdf"))
  message(paste("Saving PCoA plot for", metric_name, "to:", pcoa_file))
  ggsave(pcoa_file, plot = pcoa_plots[[metric_name]], width = 8, height = 6)
}

# Save each heatmap to a separate PDF
for (metric_name in names(heatmap_plots)) {
  if (!is.null(heatmap_plots[[metric_name]])) {
    heatmap_file <- file.path(args$output_dir, paste0("heatmap_", metric_name, ".pdf"))
    message(paste("Saving heatmap for", metric_name, "to:", heatmap_file))
    pdf(heatmap_file, width = 10, height = 8)
    draw(heatmap_plots[[metric_name]], heatmap_legend_side = "bottom", annotation_legend_side = "bottom")
    dev.off()
  }
}


saveRDS(tse, file.path(args$output_dir, "tse_object.rds"))
message("Beta diversity analysis and plotting complete.")