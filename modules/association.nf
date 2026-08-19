process differential_abundance {
    tag "Differential abundance analysis"
    publishDir "${params.results_dir}/${params.run_id}/association/differential_abundance", mode: 'copy', overwrite: false

    input:
    path asv_counts
    path asv_taxonomy
    path metadata

    output:
    path "differential_abundance_results.tsv"
    path "differential_abundance_plots.pdf"

    script:
    """
    pixi run --manifest-path ${baseDir}/env/association/pixi.toml \
        Rscript ${baseDir}/bin/differential_abundance.R \
        --input_asv_counts ${asv_counts} --input_asv_taxonomy ${asv_taxonomy} \
        --input_metadata ${metadata} --output_dir . \
        --level_to_analyze "${params.daa_level}" \
        --fixed_effect_variable "${params.grouping_variable}" \
        --top_n_taxa_plot ${params.top_n_taxa_plot} --reference_level "${params.reference_level}"
    """
}

process correlation_analysis {
    tag "Correlation analysis"
    publishDir "${params.results_dir}/${params.run_id}/association/correlation", mode: 'copy', overwrite: false

    input:
    path asv_counts
    path asv_taxonomy
    path metadata
    path alpha_diversity

    output:
    path "correlation_analysis_genus/"
    path "correlation_analysis_family/"

    script:
    """
    mkdir -p correlation_analysis_genus correlation_analysis_family
    pixi run --manifest-path ${baseDir}/env/association/pixi.toml \
        Rscript ${baseDir}/bin/correlation_analysis.R \
        --input_asv_counts ${asv_counts} --input_asv_taxonomy ${asv_taxonomy} \
        --input_metadata ${metadata} --input_alpha_diversity ${alpha_diversity} \
        --fixed_effect_variable "${params.grouping_variable}" \
        --metadata_numeric_variables "${params.metadata_numeric_variables}" \
        --level_to_analyze "Genus" --output_dir correlation_analysis_genus
    pixi run --manifest-path ${baseDir}/env/association/pixi.toml \
        Rscript ${baseDir}/bin/correlation_analysis.R \
        --input_asv_counts ${asv_counts} --input_asv_taxonomy ${asv_taxonomy} \
        --input_metadata ${metadata} --input_alpha_diversity ${alpha_diversity} \
        --fixed_effect_variable "${params.grouping_variable}" \
        --metadata_numeric_variables "${params.metadata_numeric_variables}" \
        --level_to_analyze "Family" --output_dir correlation_analysis_family
    """
}

workflow ASSOCIATION {
    take:
    asv_counts              // path
    asv_taxonomy            // path
    metadata                // path
    alpha_diversity_metrics // path

    main:
    differential_abundance(asv_counts, asv_taxonomy, metadata)
    correlation_analysis(asv_counts, asv_taxonomy, metadata, alpha_diversity_metrics)
}
