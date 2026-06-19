process tree {
    tag "Phylogenetic tree"
    label 'process_medium'
    publishDir "${params.results_dir}/${params.run_id}/diversity/phylogenetic_tree", mode: 'copy', overwrite: false

    input:
    path rep_seqs_fna

    output:
    path "rooted-tree.nwk", emit: tree

    script:
    """
    pixi run --manifest-path ${baseDir}/env/diversity/pixi.toml \
        mafft --thread ${task.cpus} --auto ${rep_seqs_fna} > aligned-rep-seqs.fna
    pixi run --manifest-path ${baseDir}/env/diversity/pixi.toml \
        fasttree -nt -gtr aligned-rep-seqs.fna > unrooted-tree.nwk
    pixi run --manifest-path ${baseDir}/env/diversity/pixi.toml \
        Rscript ${baseDir}/bin/root_tree.R \
        --input_tree unrooted-tree.nwk --output_tree rooted-tree.nwk
    """
}

process alpha_diversity {
    tag "Alpha diversity"
    publishDir "${params.results_dir}/${params.run_id}/diversity/alpha", mode: 'copy', overwrite: false

    input:
    path asv_counts
    path metadata
    path tree

    output:
    path "alpha_diversity_metrics.tsv", emit: alpha_diversity_metrics
    path "*.pdf"

    script:
    """
    pixi run --manifest-path ${baseDir}/env/diversity/pixi.toml \
        Rscript ${baseDir}/bin/alpha_diversity.R \
        --input_asv_counts ${asv_counts} --input_metadata ${metadata} \
        --input_tree ${tree} --grouping_variable "${params.grouping_variable}" \
        --output_dir .
    """
}

process beta_diversity {
    tag "Beta diversity"
    publishDir "${params.results_dir}/${params.run_id}/diversity/beta", mode: 'copy', overwrite: false

    input:
    path asv_counts
    path asv_taxonomy
    path metadata
    path tree

    output:
    path "tse_object.rds",          emit: tse
    path "community_typing.rds",    emit: community_rds
    path "permanova_results.tsv",   emit: permanova
    path "sample_clusters.tsv",     emit: clusters
    path "*.pdf"

    script:
    """
    pixi run --manifest-path ${baseDir}/env/diversity/pixi.toml \
        Rscript ${baseDir}/bin/beta_diversity.R \
        --input_asv_counts ${asv_counts} --input_asv_taxonomy ${asv_taxonomy} \
        --input_metadata ${metadata} --input_tree ${tree} \
        --grouping_variable "${params.grouping_variable}" \
        --distance_metric "${params.distance_metric}" \
        --output_dir .

    pixi run --manifest-path ${baseDir}/env/diversity/pixi.toml \
        Rscript ${baseDir}/bin/community_typing.R \
        --input_asv_counts ${asv_counts} --input_metadata ${metadata} \
        --clustering_method "${params.clustering_method}" \
        --num_clusters "${params.num_clusters}" --output_dir .
    """
}

workflow DIVERSITY {
    take:
    filtered_fasta  // path
    asv_counts      // path
    asv_taxonomy    // path
    metadata        // path

    main:
    tree(filtered_fasta)
    alpha_diversity(asv_counts, metadata, tree.out.tree)
    beta_diversity(asv_counts, asv_taxonomy, metadata, tree.out.tree)

    emit:
    tree                    = tree.out.tree
    alpha_diversity_metrics = alpha_diversity.out.alpha_diversity_metrics
    tse                     = beta_diversity.out.tse
}
