#!/usr/bin/env Rscript

# --- Dependency Checking and Installation ---
required_bioc_packages <- c("mia", "S4Vectors", "Maaslin2", "GenomeInfoDb") 

if (!requireNamespace("BiocManager", quietly = TRUE)) {
    message("Installing BiocManager...")
    install.packages("BiocManager", repos = "https://cran.rstudio.com/")
    BiocManager::install(version = "3.20")
}
for (pkg in required_bioc_packages) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    message(paste("Installing Bioconductor package:", pkg))
    BiocManager::install(pkg)
  }
}

# --- Load Required Libraries ---
library(argparse)
library(data.table)
library(mia)
library(S4Vectors)
library(ggplot2)
library(dplyr)
library(patchwork)
library(Maaslin2)
library(tidyr) # For pivot_longer


# --- Argument Parsing ---
parser <- ArgumentParser(description='Perform differential abundance analysis using Maaslin2.')

parser$add_argument('--input_asv_counts', type='character', help='Path to the cleaned ASV count table (TSV).', required=TRUE)
parser$add_argument('--input_asv_taxonomy', type='character', help='Path to the ASV taxonomy table (TSV).', required=TRUE)
parser$add_argument('--input_metadata', type='character', help='Path to the sample metadata table (TSV).', required=TRUE)
parser$add_argument('--output_dir', type='character', help='Output directory for DAA results and plots.', required=TRUE)
parser$add_argument('--level_to_analyze', type='character', default='Genus', help='Taxonomic level for DAA (e.g., "ASV", "Genus", "Family", "Phylum").')
parser$add_argument('--fixed_effect_variable', type='character', help='Name of the column in metadata to test for differential abundance.', required=TRUE)
parser$add_argument('--random_effects_variable', type='character', default=NULL, help='Name of the column in metadata to use as random effects (optional).')
parser$add_argument('--min_prevalence_percent', type='double', default=10.0, help='Minimum prevalence percentage for features to be included in DAA (e.g., 10.0 for 10%%).')
parser$add_argument('--q_value_threshold', type='double', default=0.05, help='Q-value threshold for significance.')
parser$add_argument('--top_n_taxa_plot', type='integer', default=10, help='Number of top significant taxa to plot individual boxplots for.')
parser$add_argument('--reference_level', type='character', default=NULL, help='Reference level for the fixed effect variable. If NULL, Maaslin2 picks the first factor level.')

args <- parser$parse_args()
args$fixed_effect_variable <- trimws(args$fixed_effect_variable)
if (!is.null(args$random_effects_variable)) args$random_effects_variable <- trimws(args$random_effects_variable)

# Create output directory if it doesn't exist
if (!dir.exists(args$output_dir)) {
    dir.create(args$output_dir, recursive = TRUE)
}

# --- Utility function to read TSV data ---
read_tsv_data <- function(filepath, is_matrix=FALSE, has_rownames=TRUE) {
    # check.names = FALSE preserves hyphens and other special characters
    df <- fread(filepath, sep="\t", header=TRUE, data.table=FALSE, check.names = FALSE)
    
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

message(paste("Loading ASV taxonomy from:", args$input_asv_taxonomy))
taxonomy_df <- read_tsv_data(args$input_asv_taxonomy, has_rownames=TRUE)

message(paste("Loading metadata from:", args$input_metadata))
metadata_df <- read_tsv_data(args$input_metadata, has_rownames=TRUE)


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


# --- Agglomerate if needed ---
if (tolower(args$level_to_analyze) != "asv") {
    message(paste("Agglomerating data to", args$level_to_analyze, "level for DAA..."))
    # Ensure the rank exists in the rowData
    if (!args$level_to_analyze %in% colnames(rowData(tse))) {
        stop(paste("Taxonomic rank '", args$level_to_analyze, "' not found in taxonomy data. Cannot agglomerate."))
    }
    tse <- agglomerateByRank(tse, rank = args$level_to_analyze)
    message(paste("Agglomerated TSE has dimensions:", dim(tse)[1], "features and", dim(tse)[2], "samples."))
}


# --- Filter by prevalence (as Maaslin2 can take 0s, but filtering helps) ---
message(paste("Filtering features with less than", args$min_prevalence_percent, "percent prevalence..."))
tse <- mia::subsetByPrevalent(tse, 
                               rank = args$level_to_analyze, 
                               prevalence = args$min_prevalence_percent / 100, 
                               detection = 1) # At least 1 count in a sample
message(paste("TSE after prevalence filtering has dimensions:", dim(tse)[1], "features and", dim(tse)[2], "samples."))
if (nrow(tse) == 0) {
    stop("No features remaining after prevalence filtering. Adjust --min_prevalence_percent.")
}


# --- Prepare metadata for Maaslin2 ---
message("Preparing metadata and running Maaslin2...")
metadata_for_maaslin <- S4Vectors::as.data.frame(colData(tse))

# Ensure fixed effect variable is a factor
if (!args$fixed_effect_variable %in% names(metadata_for_maaslin)) {
    # Check if R's automatic name sanitization changed the name (e.g., hyphen to dot)
    safe_var <- make.names(args$fixed_effect_variable)
    if (safe_var %in% names(metadata_for_maaslin)) {
        message(paste0("Fixed effect variable '", args$fixed_effect_variable, "' not found, but found sanitized version '", safe_var, "'. Using '", safe_var, "' instead."))
        args$fixed_effect_variable <- safe_var
    } else {
        stop(paste0("Fixed effect variable '", args$fixed_effect_variable, "' not found in metadata. Available columns: ", paste(names(metadata_for_maaslin), collapse=", ")))
    }
}
metadata_for_maaslin[[args$fixed_effect_variable]] <- as.factor(metadata_for_maaslin[[args$fixed_effect_variable]])

# Set reference level if specified
if (!is.null(args$reference_level)) {
    if (!args$reference_level %in% levels(metadata_for_maaslin[[args$fixed_effect_variable]])) {
        stop(paste0("Reference level '", args$reference_level, "' not found in levels of '", args$fixed_effect_variable, "'."))
    }
    metadata_for_maaslin[[args$fixed_effect_variable]] <- relevel(metadata_for_maaslin[[args$fixed_effect_variable]], ref = args$reference_level)
}

# Define fixed and random effects
fixed_effects <- c(args$fixed_effect_variable)
random_effects <- NULL
if (!is.null(args$random_effects_variable)) {
    if (!args$random_effects_variable %in% names(metadata_for_maaslin)) {
        # Check if R's automatic name sanitization changed the name (e.g., hyphen to dot)
        safe_random_var <- make.names(args$random_effects_variable)
        if (safe_random_var %in% names(metadata_for_maaslin)) {
            message(paste0("Random effects variable '", args$random_effects_variable, "' not found, but found sanitized version '", safe_random_var, "'. Using '", safe_random_var, "' instead."))
            args$random_effects_variable <- safe_random_var
        } else {
            warning(paste0("Random effects variable '", args$random_effects_variable, "' not found in metadata. Ignoring random effects."))
        }
    }
    
    if (args$random_effects_variable %in% names(metadata_for_maaslin)) {
        metadata_for_maaslin[[args$random_effects_variable]] <- as.factor(metadata_for_maaslin[[args$random_effects_variable]])
        random_effects <- c(args$random_effects_variable)
    }
}


# --- Run Maaslin2 ---
maaslin2_output_dir <- file.path(args$output_dir, "Maaslin2_output")
if (!dir.exists(maaslin2_output_dir)) {
    dir.create(maaslin2_output_dir, recursive = TRUE)
}

fit_data <- Maaslin2(
    input_data = assay(tse, "counts"), # Maaslin2 will handle its own normalization/transformations, but often works well on raw counts.
    input_metadata = metadata_for_maaslin,
    output = maaslin2_output_dir,
    fixed_effects = fixed_effects,
    random_effects = random_effects,
    normalization = "TSS", # Total Sum Scaling, as recommended in PDF
    transform = "LOG", # Log transform, as recommended in PDF
    min_abundance = 0.0, # Do not filter by abundance here, already done by prevalence
    min_prevalence = 0.0, # Do not filter by prevalence here, already done by mia::subsetByPrevalent
    plot_heatmap = FALSE,
    plot_scatter = FALSE
)


# --- Extract and Filter Results ---
message("Processing Maaslin2 results...")
results_df <- fit_data$results %>%
    filter(qval < args$q_value_threshold) %>%
    arrange(qval)

# Check if CI columns exist, if not, calculate them
if (!"ci_low" %in% names(results_df)) {
    if ("stderr" %in% names(results_df)) {
         results_df$ci_low <- results_df$coef - 1.96 * results_df$stderr
         results_df$ci_high <- results_df$coef + 1.96 * results_df$stderr
    } else {
         warning("Standard error not found in Maaslin2 results. Cannot calculate CIs. Plotting points only.")
         results_df$ci_low <- results_df$coef
         results_df$ci_high <- results_df$coef
    }
}

if (nrow(results_df) == 0) {
    message("No significant features found at the specified q-value threshold. Skipping plots.")
} else {
    message(paste("Found", nrow(results_df), "significant features."))

    # --- Multi-page Log2FC plot with Confidence Intervals ---
    message("Generating multi-page Log2FC plot...")

    # Clean feature labels and order facets by number of significant taxa
    results_df$feature <- gsub("\\.", " ", results_df$feature)
    facet_order <- results_df %>%
        count(value) %>%
        arrange(desc(n)) %>%
        pull(value)
    results_df$value <- factor(results_df$value, levels = facet_order)

    # Order features by absolute coefficient within each facet
    results_df <- results_df %>%
        group_by(value) %>%
        mutate(feature_label = factor(feature, levels = rev(unique(feature[order(abs(coef))])))) %>%
        ungroup()

    facets_per_page <- 2
    facet_groups <- split(facet_order, ceiling(seq_along(facet_order) / facets_per_page))

    # Open PDF device for multi-page output
    output_plot_file <- file.path(args$output_dir, "differential_abundance_plots.pdf")
    pdf(output_plot_file, width = 10, height = 14)

    for (i in seq_along(facet_groups)) {
        group_facets <- facet_groups[[i]]
        group_data <- results_df %>% filter(value %in% group_facets)

        p <- ggplot(group_data, aes(x = coef, y = feature_label)) +
            geom_vline(xintercept = 0, linetype = "dashed", color = "grey60") +
            geom_errorbarh(aes(xmin = ci_low, xmax = ci_high),
                           height = 0.15, alpha = 0.5, color = "grey40") +
            geom_point(aes(color = ifelse(coef > 0, "Increased", "Decreased")),
                       size = 1.5) +
            facet_wrap(~value, scales = "free_y", ncol = 1, strip.position = "left") +
            labs(
                title = if (i == 1) paste0("Significant Differential Abundance (", args$level_to_analyze, " level)") else NULL,
                x = "Log2 Fold Change (Effect Size)",
                y = NULL,
                color = "Direction"
            ) +
            theme_minimal(base_size = 10) +
            theme(
                axis.text.y = element_text(size = 6, family = "mono"),
                axis.text.x = element_text(size = 8),
                strip.text = element_text(size = 9, face = "bold", color = "white"),
                strip.background = element_rect(fill = "#2c3e50", color = NA),
                strip.placement = "outside",
                panel.spacing = unit(1.0, "lines"),
                plot.title = element_text(size = 12, face = "bold"),
                legend.position = if (i == length(facet_groups)) "bottom" else "none",
                legend.title = element_text(size = 9),
                legend.text = element_text(size = 8),
                plot.margin = margin(10, 10, 10, 10)
            ) +
            scale_color_manual(values = c("Increased" = "#c0392b", "Decreased" = "#2980b9")) +
            guides(color = guide_legend(override.aes = list(size = 3)))

        print(p)
    }

    # --- Plot Individual Boxplots for Top N Significant Taxa (unchanged) ---
    message(paste("Generating individual boxplots for top", args$top_n_taxa_plot, "significant taxa..."))
    top_n_features_sanitized <- results_df %>%
        filter(metadata == args$fixed_effect_variable) %>%
        head(args$top_n_taxa_plot) %>%
        pull(feature)

    # Map sanitized names back to original TSE rownames
    # Maaslin2 sanitizes names (like make.names), so we need to match them
    original_rownames <- rownames(tse)
    sanitized_rownames <- make.names(original_rownames)
    
    # Create a lookup vector
    name_map <- setNames(original_rownames, sanitized_rownames)
    
    # Find the original names for the top features
    # We check if the name is directly in rownames, otherwise try the map
    top_n_features_original <- sapply(top_n_features_sanitized, function(x) {
        if (x %in% original_rownames) {
            return(x)
        } else if (x %in% names(name_map)) {
            return(name_map[[x]])
        } else {
            warning(paste("Feature", x, "not found in TSE object. Skipping."))
            return(NA)
        }
    })
    
    # Remove NAs found
    top_n_features_original <- top_n_features_original[!is.na(top_n_features_original)]

    if (length(top_n_features_original) == 0) {
        warning("No top features could be mapped back to the data. Skipping boxplots.")
    } else {
        # Subset TSE for plotting using valid original names
        tse_plot <- tse[top_n_features_original, ]
        
        # We also need to update the names in the results_df or just rely on the fact that
        # plotBoxplot will use the rownames of tse_plot. 
        # However, to facet correctly by 'feature', we might want consistency.
        # But miaViz::plotBoxplot works on the TSE object, so it uses the original names.
    
    # Plot boxplots using miaViz::plotBoxplot
    plot_individual_boxplots <- NULL
    
    if (exists("tse_plot") && !is.null(tse_plot)) {
        # Need to transform to relabundance first for plotBoxplot
        tse_plot <- transformAssay(tse_plot, method = "relabundance", name = "relabundance")
    
        # Convert TSE data to long format for ggplot2
        # Extract relative abundance matrix
        rel_abund_mat <- assay(tse_plot, "relabundance")
        
        # Melt to long format
        # features are rows, samples are columns
        # We want: SampleID, Feature, Abundance, Group
        
        plot_data <- as.data.frame(t(rel_abund_mat))
        plot_data$SampleID <- rownames(plot_data)
        
        # Add metadata with a safe name for plotting
        meta_cols <- colData(tse_plot)
        group_col_name <- "Group"
        
        # Helper function to normalize names for matching (remove punctuation, lower case)
        normalize_name <- function(x) {
            tolower(gsub("[[:punct:]]", "", x))
        }
        
        # Try finding the variable
        if (args$fixed_effect_variable %in% names(meta_cols)) {
            plot_data[[group_col_name]] <- meta_cols[[args$fixed_effect_variable]]
        } else {
             # Try fuzzy matching
             target_norm <- normalize_name(args$fixed_effect_variable)
             available_norm <- normalize_name(names(meta_cols))
             
             match_idx <- which(available_norm == target_norm)
             
             if (length(match_idx) == 1) {
                 found_name <- names(meta_cols)[match_idx]
                 message(paste0("Found grouping variable '", found_name, "' in colData (matched '", args$fixed_effect_variable, "')."))
                 plot_data[[group_col_name]] <- meta_cols[[found_name]]
             } else {
                 # Also try make.names just in case
                 safe_var <- make.names(args$fixed_effect_variable)
                 if (safe_var %in% names(meta_cols)) {
                     plot_data[[group_col_name]] <- meta_cols[[safe_var]]
                 } else {
                     stop(paste0("Could not find grouping variable '", args$fixed_effect_variable, "' in colData. Available columns: ", paste(names(meta_cols), collapse=", ")))
                 }
             }
        }
        
        # Ensure Group is a factor
        plot_data[[group_col_name]] <- as.factor(plot_data[[group_col_name]])

        # Pivot longer for faceting by feature
        # Ensure we don't pass a named vector to all_of(), which causes tidyselect issues
        cols_to_pivot <- unname(top_n_features_original)
        
        plot_data_long <- plot_data %>%
            tidyr::pivot_longer(
                cols = all_of(cols_to_pivot), 
                names_to = "Feature", 
                values_to = "Abundance"
            )

        # Plot using ggplot2 with safe column name "Group"
        plot_individual_boxplots <- ggplot(plot_data_long, aes(x = Group, y = Abundance, fill = Group)) +
            geom_violin(alpha = 0.6, trim = FALSE) +
            geom_boxplot(width = 0.2, alpha = 0.8, outlier.shape = NA) +
            geom_jitter(width = 0.1, size = 1, alpha = 0.5) +
            facet_wrap(~Feature, scales = "free_y", ncol = 2) +
            labs(
                title = paste("Relative Abundance of Top", length(top_n_features_original), "Significant", args$level_to_analyze, "by", args$fixed_effect_variable),
                y = "Relative Abundance",
                x = args$fixed_effect_variable,
                fill = args$fixed_effect_variable
            ) +
            theme_minimal() +
            theme(
                axis.text.x = element_text(angle = 45, hjust = 1),
                legend.position = "none" # Redundant with x-axis
            )
    }
    } # Close the else block for feature mapping (from previous edit)

    # Print boxplots page if available, then close PDF
    if (exists("plot_individual_boxplots") && !is.null(plot_individual_boxplots)) {
        print(plot_individual_boxplots)
    }
    dev.off()
    message(paste("Saving DAA plots to:", output_plot_file))
}

# --- Save all Maaslin2 results ---
all_results_output_file <- file.path(args$output_dir, "Maaslin2_all_results.tsv")
message(paste("Saving all Maaslin2 results to:", all_results_output_file))
fwrite(fit_data$results, file = all_results_output_file, sep = "	", quote = FALSE, row.names = FALSE)


message("Differential abundance analysis complete.")