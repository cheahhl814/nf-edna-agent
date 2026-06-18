#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors)
library(sechm, exclude = "meltSE")
library(ComplexHeatmap) # sechm uses gpar from this package
library(ggplot2)


# --- Argument Parsing ---
parser <- ArgumentParser(description='Plot abundance heatmaps with CLR transformation and standardization at different taxonomic levels.')

parser$add_argument('--input_phylum_relabund', type='character', help='Path to the Phylum-level relative abundance table (TSV).', required=TRUE)
parser$add_argument('--input_phylum_taxonomy', type='character', help='Path to the Phylum-level taxonomy table (TSV).', required=TRUE)
parser$add_argument('--input_family_relabund', type='character', help='Path to the Family-level relative abundance table (TSV).', required=TRUE)
parser$add_argument('--input_family_taxonomy', type='character', help='Path to the Family-level taxonomy table (TSV).', required=TRUE)
parser$add_argument('--input_genus_relabund', type='character', help='Path to the Genus-level relative abundance table (TSV).', required=TRUE)
parser$add_argument('--input_genus_taxonomy', type='character', help='Path to the Genus-level taxonomy table (TSV).', required=TRUE)
parser$add_argument('--metadata_file', type='character', help='Path to the sample metadata table (TSV).', required=TRUE)
parser$add_argument('--output_dir', type='character', help='Output directory for heatmaps.', required=TRUE)
parser$add_argument('--group_by', type='character', help='Metadata column to group/average samples by (e.g., "condition"). If not provided, individual samples are plotted.')
parser$add_argument('--top_n', type='integer', default=50, help='Number of top most abundant taxa to display in the heatmap (default: 50).')

args <- parser$parse_args()

# Create output directory if it doesn't exist
if (!dir.exists(args$output_dir)) {
    dir.create(args$output_dir, recursive = TRUE)
}

# --- Function to load data, create TSE, transform, plot, and save ---
plot_level_heatmap <- function(relabund_file, taxonomy_file, metadata_file, output_dir, level_name, group_by_var = NULL, top_n = 50) {
    message(paste("Generating heatmap for", level_name, "level..."))
    
    # --- Load Data ---
    # Function to read TSV files robustly
    read_tsv_data <- function(filepath, is_matrix=FALSE) {
        df <- fread(filepath, sep="	", header=TRUE, data.table=FALSE)
        
        row_id_col_name <- names(df)[1]
        
        if (is.null(row_id_col_name) || row_id_col_name == "" || row_id_col_name == "V1") {
            rownames(df) <- df[[1]]
            df <- df[, -1, drop=FALSE]
        } else {
            rownames(df) <- df[[row_id_col_name]]
            df <- df[, -which(names(df) == row_id_col_name), drop=FALSE]
        }

        if (is_matrix) {
            matrix_data <- as.matrix(df)
            mode(matrix_data) <- "numeric"
            return(matrix_data)
        } else {
            return(df)
        }
    }

    relabund_matrix <- read_tsv_data(relabund_file, is_matrix=TRUE)
    taxonomy_df_level <- read_tsv_data(taxonomy_file)
    metadata_df <- read_tsv_data(metadata_file)
    
    # Re-align metadata rownames based on 'sample-id' if it was present
    if ("sample-id" %in% colnames(metadata_df)) { # If 'sample-id' is still a column, it means it wasn't the first column
         rownames(metadata_df) <- metadata_df$`sample-id`
         metadata_df$`sample-id` <- NULL
    }

    # Ensure all tables have aligned samples and features after reading
    common_samples <- intersect(colnames(relabund_matrix), rownames(metadata_df))
    if (length(common_samples) == 0) {
        stop(paste("No common samples for", level_name, "between relative abundance table and metadata."))
    }
    relabund_matrix <- relabund_matrix[, common_samples, drop=FALSE]
    metadata_df <- metadata_df[common_samples, , drop=FALSE]

    common_features <- intersect(rownames(relabund_matrix), rownames(taxonomy_df_level))
    if (length(common_features) == 0) {
        stop(paste("No common features for", level_name, "between relative abundance table and taxonomy table."))
    }
    relabund_matrix <- relabund_matrix[common_features, , drop=FALSE]
    taxonomy_df_level <- taxonomy_df_level[common_features, , drop=FALSE]
    
    # --- Top N Taxa Selection ---
    if (!is.null(top_n) && top_n > 0 && top_n < nrow(relabund_matrix)) {
        message(paste("Limiting to top", top_n, "most abundant taxa..."))
        mean_abundances <- rowMeans(relabund_matrix)
        top_taxa <- names(sort(mean_abundances, decreasing = TRUE))[1:min(top_n, length(mean_abundances))]
        relabund_matrix <- relabund_matrix[top_taxa, , drop=FALSE]
        taxonomy_df_level <- taxonomy_df_level[top_taxa, , drop=FALSE]
    }

    # --- Sample Merging / Averaging ---
    if (!is.null(group_by_var) && group_by_var %in% colnames(metadata_df)) {
        message(paste("Merging replicates by averaging across:", group_by_var))
        groups <- as.factor(metadata_df[[group_by_var]])
        
        # Calculate mean per group for each taxon
        relabund_matrix_avg <- do.call(cbind, lapply(levels(groups), function(g) {
            rowMeans(relabund_matrix[, groups == g, drop=FALSE])
        }))
        colnames(relabund_matrix_avg) <- levels(groups)
        
        # Create new simplified metadata for groups
        group_metadata <- data.frame(
            row.names = levels(groups)
        )
        group_metadata[[group_by_var]] <- levels(groups)
        
        # Update matrices and metadata for downstream TSE
        relabund_matrix <- relabund_matrix_avg
        metadata_df <- group_metadata
    }

    # --- Create TreeSummarizedExperiment Object ---
    tse_level <- TreeSummarizedExperiment(
        assays = SimpleList(relabundance = relabund_matrix),
        rowData = S4Vectors::DataFrame(taxonomy_df_level),
        colData = S4Vectors::DataFrame(metadata_df)
    )

    # --- Apply CLR transformation and standardization ---
    # Apply CLR transformation (mia handles pseudocounts for zeros)
    tse_level <- transformAssay(tse_level, assay.type = "relabundance", method = "clr", pseudocount = 1, name = "clr")
    
    # Apply standardization (Z-score transformation)
    # MARGIN = "rows" means standardization is applied to each feature (row)
    tse_level <- transformAssay(tse_level, assay.type = "clr", MARGIN = "rows", method = "standardize", name = "clr_z")
    
    # --- Generate Heatmap ---
    plot_title <- paste("Top ", nrow(relabund_matrix), " ", level_name, sep="")
    if (!is.null(group_by_var)) {
        plot_title <- paste(plot_title, " (Averaged by ", group_by_var, ")", sep="")
    }
    
    # Determine annotation
    if (!is.null(group_by_var) && group_by_var %in% colnames(metadata_df)) {
        top_anno <- HeatmapAnnotation(
            df = metadata_df[, group_by_var, drop=FALSE],
            show_legend = TRUE
        )
    } else {
        top_anno <- NULL
    }
    
    # Create the heatmap
    heatmap_plot <- sechm(
        tse_level,
        assayName = "clr_z", # Use the standardized CLR assay
        features = rownames(tse_level),
        show_rownames = TRUE,
        show_colnames = TRUE,
        cluster_rows = TRUE, # Cluster rows (taxa)
        cluster_cols = TRUE, # Cluster columns (samples/groups)
        name = "clr_z", # Name for the color bar legend
        row_names_gp = gpar(fontsize = 8), # Adjust row name font size
        column_names_gp = gpar(fontsize = 8), # Adjust column name font size
        hmcols = colorRampPalette(c("blue", "white", "red"))(100), # Define color scale for clr_z
        column_title = plot_title,
        top_annotation = top_anno
    )

    # --- Save Plot ---
    output_filename <- file.path(output_dir, paste0("heatmap_", tolower(level_name), ".pdf"))
    pdf(output_filename, width = 12, height = 10) # Open PDF device
    draw(heatmap_plot) # Draw the ComplexHeatmap object
    dev.off() # Close PDF device
    message(paste("Saved heatmap to:", output_filename))
}


# --- Process each taxonomic level ---

# Load metadata once, it's common for all plots
metadata_df_path <- args$metadata_file

# Phylum Level
plot_level_heatmap(
    args$input_phylum_relabund,
    args$input_phylum_taxonomy,
    metadata_df_path,
    args$output_dir,
    "Phylum",
    group_by_var = args$group_by,
    top_n = args$top_n
)

# Family Level
plot_level_heatmap(
    args$input_family_relabund,
    args$input_family_taxonomy,
    metadata_df_path,
    args$output_dir,
    "Family",
    group_by_var = args$group_by,
    top_n = args$top_n
)

# Genus Level
plot_level_heatmap(
    args$input_genus_relabund,
    args$input_genus_taxonomy,
    metadata_df_path,
    args$output_dir,
    "Genus",
    group_by_var = args$group_by,
    top_n = args$top_n
)

message("All requested abundance heatmaps generated.")