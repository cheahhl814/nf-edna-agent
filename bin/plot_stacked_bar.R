#!/usr/bin/env Rscript


# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors)
library(miaViz)
library(ggplot2) # For theme customizations


# --- Argument Parsing ---
parser <- ArgumentParser(description='Plot stacked bar charts of community composition at different taxonomic levels.')

parser$add_argument('--input_phylum_relabund', type='character', help='Path to the Phylum-level relative abundance table (TSV).', required=TRUE)
parser$add_argument('--input_phylum_taxonomy', type='character', help='Path to the Phylum-level taxonomy table (TSV).', required=TRUE)
parser$add_argument('--input_family_relabund', type='character', help='Path to the Family-level relative abundance table (TSV).', required=TRUE)
parser$add_argument('--input_family_taxonomy', type='character', help='Path to the Family-level taxonomy table (TSV).', required=TRUE)
parser$add_argument('--input_genus_relabund', type='character', help='Path to the Genus-level relative abundance table (TSV).', required=TRUE)
parser$add_argument('--input_genus_taxonomy', type='character', help='Path to the Genus-level taxonomy table (TSV).', required=TRUE)
parser$add_argument('--metadata_file', type='character', help='Path to the sample metadata table (TSV).', required=TRUE)
parser$add_argument('--group_by', type='character', help='Metadata column to group/merge samples by (e.g., to merge replicates).', default=NULL)
parser$add_argument('--output_dir', type='character', help='Output directory for plots.', required=TRUE)
parser$add_argument('--top_n_taxa', type='integer', default=20, help='Number of top taxa to display individually, others will be grouped as "Other".')

args <- parser$parse_args()

# Create output directory if it doesn't exist
if (!dir.exists(args$output_dir)) {
    dir.create(args$output_dir, recursive = TRUE)
}

# --- Function to load data, create TSE, lump rare taxa, plot, and save ---
plot_level_composition <- function(relabund_file, taxonomy_file, metadata_file, output_dir, level_name, top_n_taxa) {
    message(paste("Generating stacked bar chart for", level_name, "level..."))
    
    # --- Load Data ---
    # Function to read TSV files robustly
    read_tsv_data <- function(filepath, is_counts=FALSE) {
        df <- fread(filepath, sep="	", header=TRUE, data.table=FALSE)
        
        row_id_col_name <- names(df)[1]
        if (is.null(row_id_col_name) || row_id_col_name == "" || row_id_col_name == "V1") {
            rownames(df) <- df[[1]]
            df <- df[, -1, drop=FALSE]
        } else {
            rownames(df) <- df[[row_id_col_name]]
            df <- df[, -which(names(df) == row_id_col_name), drop=FALSE]
        }

        if (is_counts) {
            matrix_data <- as.matrix(df)
            mode(matrix_data) <- "numeric"
            return(matrix_data)
        } else {
            return(df)
        }
    }

    relabund_matrix <- read_tsv_data(relabund_file, is_counts=TRUE)
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

    level_name <- trimws(level_name)
    
    # --- Create TreeSummarizedExperiment Object ---
    # Store original column names for reference
    colnames(metadata_df) <- trimws(colnames(metadata_df))
    
    tse_level <- TreeSummarizedExperiment(
        assays = SimpleList(relabundance = relabund_matrix),
        rowData = S4Vectors::DataFrame(taxonomy_df_level),
        colData = S4Vectors::DataFrame(metadata_df)
    )

    # --- Merge Samples (Replicates) if group_by is provided ---
    if (!is.null(args$group_by)) {
        requested_col <- trimws(args$group_by)
        available_cols <- colnames(colData(tse_level))
        
        # Robust matching: ignore case, hyphens, and dots
        clean_name <- function(x) tolower(gsub("[._-]", "", x))
        match_idx <- match(clean_name(requested_col), clean_name(available_cols))
        
        if (!is.na(match_idx)) {
            group_col <- available_cols[match_idx]
            message(paste0("Merging samples based on column: '", group_col, "'"))
            
            # Record group sizes for averaging
            group_info <- as.character(colData(tse_level)[[group_col]])
            group_sizes <- table(group_info)
            
            # Agglomerate by columns (sums abundances by default)
            tse_level <- agglomerateByVariable(tse_level, by = "cols", f = group_col)
            
            # Ensure assay name is correct
            if (!"relabundance" %in% assayNames(tse_level)) {
                assayNames(tse_level)[1] <- "relabundance"
            }
            
            # Divide by group sizes to get the average (since input was relative abundance)
            current_groups <- colnames(tse_level)
            assay(tse_level, "relabundance") <- sweep(
                assay(tse_level, "relabundance"), 
                2, 
                as.numeric(group_sizes[current_groups]), 
                "/"
            )
            
            message(paste("Successfully merged into", ncol(tse_level), "groups."))
        } else {
            # Print available columns clearly for debugging
            col_list <- paste0("[", available_cols, "]", collapse=", ")
            warning(paste0("Grouping column '", requested_col, "' not found. Available columns: ", col_list, ". Skipping merging."))
        }
    }

    # --- Lumping rare taxa into "Other" for visualization ---
    available_ranks <- colnames(rowData(tse_level))
    match_idx <- match(tolower(level_name), tolower(available_ranks))
    
    if (is.na(match_idx)) {
      warning(paste("Taxonomic rank column '", level_name, "' not found in taxonomy. Available columns: ", paste(available_ranks, collapse=", "), ". Plotting without lumping."))
      rowData(tse_level)$TaxonName <- rownames(tse_level)
      tse_for_plot <- tse_level
      plot_rank <- "TaxonName"
      plot_title <- paste("Community Composition (", level_name, " Level)", sep="")
      real_rank <- level_name
    } else {
      real_rank <- available_ranks[match_idx]
      top_taxa_names <- getTop(tse_level, top = top_n_taxa, assay.type = "relabundance")
      
      lumped_taxonomy <- lapply(rowData(tse_level)[[real_rank]], function(x) {
          if (x %in% top_taxa_names) { as.character(x) } else { "Other" }
      })
      rowData(tse_level)$LumpedTaxa <- as.character(lumped_taxonomy)
      
      tse_for_plot <- agglomerateByVariable(tse_level, by = "rows", f = "LumpedTaxa")
      plot_rank <- "LumpedTaxa"
      plot_title <- paste("Community Composition (Top", top_n_taxa, real_rank, " + Other)")
    }

    # --- Sorting Taxa by Abundance ---
    # Calculate total abundance per taxon
    taxa_abundances <- rowSums(assay(tse_for_plot, "relabundance"))
    sorted_taxa <- names(sort(taxa_abundances, decreasing = TRUE))
    
    # Ensure "Other" is always at the last position (top of stack)
    if ("Other" %in% sorted_taxa) {
        sorted_taxa <- c(sorted_taxa[sorted_taxa != "Other"], "Other")
    }
    
    # Physicall reorder the TSE rows by abundance to force internal miaz/ggplot logic
    # Standard ggplot stacks from bottom to top based on level 1, 2, ...
    # We want level 1 (Most Abundant) at the bottom.
    tse_for_plot <- tse_for_plot[sorted_taxa, ]
    
    # Apply factor levels (Most Abundant = level 1 = bottom)
    rowData(tse_for_plot)[[plot_rank]] <- factor(
        rowData(tse_for_plot)[[plot_rank]], 
        levels = sorted_taxa
    )

    # --- Color Palette ---
    high_contrast_palette <- c(
        "#E6194B", "#3CB44B", "#FFE119", "#4363D8", "#F58231", "#911EB4", "#42D4F4", "#F032E6", 
        "#BFEF45", "#FABEBE", "#069990", "#E6BEFF", "#9A6324", "#FFFAC8", "#800000", "#AAFFC3", 
        "#808000", "#FFD8B1", "#000075", "#A9A9A9", "#2ECC71", "#3498DB", "#E74C3C", "#F1C40F", 
        "#8E44AD", "#16A085", "#D35400", "#2980B9", "#27AE60", "#F39C12"
    )
    
    # Map colors to taxa in abundance order
    plot_colors <- rep(high_contrast_palette, length.out = length(sorted_taxa))
    names(plot_colors) <- sorted_taxa
    if ("Other" %in% names(plot_colors)) {
        plot_colors["Other"] <- "#D3D3D3" # Light Grey
    }

    # --- Generate Plot ---
    # We use NULL for ordering to respect our physical row order and factor levels
    p <- plotAbundance(
        tse_for_plot,
        assay.type = "relabundance",
        rank = plot_rank,
        min.abundance = 0.0001,
        order.row.by = NULL,
        order.col.by = NULL,
        layout = "bar",
        title = plot_title
    ) +
    theme_minimal() +
    theme(
        axis.text.x = element_text(angle = 90, hjust = 1, vjust = 0.5, size = 8),
        legend.text = element_text(size = 8),
        legend.title = element_text(size = 10, face = "bold"),
        panel.grid.major.x = element_blank()
    ) +
    scale_fill_manual(values = plot_colors, breaks = sorted_taxa) + 
    guides(fill = guide_legend(override.aes = list(colour = NA)), colour = "none") +
    labs(fill = real_rank, y = "Relative Abundance", x = "Samples")

    # Force remove bar borders
    if (length(p$layers) > 0) {
        p$layers[[1]]$aes_params$colour <- NA
    }

    # --- Save Plot ---
    output_filename <- file.path(output_dir, paste0("stacked_bar_chart_", tolower(level_name), ".pdf"))
    ggsave(output_filename, plot = p, width = 12, height = 8)
    message(paste("Saved stacked bar chart to:", output_filename))
}


# --- Process each taxonomic level ---

# Load metadata once, it's common for all plots
metadata_df_path <- args$metadata_file

# Phylum Level
plot_level_composition(
    args$input_phylum_relabund,
    args$input_phylum_taxonomy,
    metadata_df_path,
    args$output_dir,
    "Phylum",
    args$top_n_taxa
)

# Family Level
plot_level_composition(
    args$input_family_relabund,
    args$input_family_taxonomy,
    metadata_df_path,
    args$output_dir,
    "Family",
    args$top_n_taxa
)

# Genus Level
plot_level_composition(
    args$input_genus_relabund,
    args$input_genus_taxonomy,
    metadata_df_path,
    args$output_dir,
    "Genus",
    args$top_n_taxa
)

message("All requested stacked bar charts generated.")