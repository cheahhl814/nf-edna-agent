process classification_idtaxa {
    tag "IDTAXA classification"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    path rep_seqs_fna
    path idtaxa_model

    output:
    path "idtaxa_classification.tsv"
    path "idtaxa_classification_confident.tsv", emit: taxonomy_table
    path "idtaxa_confidence.tsv",               emit: confidence

    script:
    """
    pixi run --manifest-path ${baseDir}/env/classification/pixi.toml \
        Rscript ${baseDir}/bin/idtaxa.R \
        --query_sequences ${rep_seqs_fna} --idtaxa_model ${idtaxa_model} \
        --output_classification idtaxa_classification.tsv \
        --output_confidence idtaxa_confidence.tsv

    pixi run --manifest-path ${baseDir}/env/pixi.toml \
        julia ${baseDir}/bin/filter_idtaxa_by_confidence.jl \
        --classification_file idtaxa_classification.tsv \
        --confidence_file idtaxa_confidence.tsv \
        --output_file idtaxa_classification_confident.tsv
    """
}

process agglomerate {
    tag "Agglomerate by taxonomy"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy", mode: 'copy', overwrite: false

    input:
    path asv_counts
    path taxonomy_table
    path metadata
    path asv_fasta

    output:
    path "agglomerated_data/asv_counts.tsv",    emit: asv_counts
    path "agglomerated_data/asv_taxonomy.tsv",  emit: asv_taxonomy
    path "agglomerated_data/genus_counts.tsv",  emit: genus_counts
    path "agglomerated_data/genus_taxonomy.tsv"
    path "agglomerated_data/family_counts.tsv"
    path "agglomerated_data/family_taxonomy.tsv"
    path "agglomerated_data/phylum_counts.tsv"
    path "agglomerated_data/phylum_taxonomy.tsv"
    path "filtered_asvs.fna",                   emit: filtered_fasta

    script:
    """
    pixi run --manifest-path ${baseDir}/env/classification/pixi.toml \
        Rscript ${baseDir}/bin/agglomerate_data.R \
        --asv_counts_file ${asv_counts} --taxonomy_file ${taxonomy_table} \
        --metadata_file ${metadata} --output_dir agglomerated_data \
        --kingdoms ${params.kingdoms} --ranks ${params.target_ranks}

    tail -n +2 agglomerated_data/asv_counts.tsv | awk '{print \$1}' > asv_ids_to_keep.txt
    pixi run --manifest-path ${baseDir}/env/classification/pixi.toml \
        seqtk subseq ${asv_fasta} asv_ids_to_keep.txt > filtered_asvs.fna
    """
}

workflow CLASSIFY {
    take:
    asv_table    // path
    rep_seqs     // path
    idtaxa_model // path
    metadata     // path

    main:
    classification_idtaxa(rep_seqs, idtaxa_model)
    agglomerate(
        asv_table,
        classification_idtaxa.out.taxonomy_table,
        metadata,
        rep_seqs
    )

    emit:
    asv_counts      = agglomerate.out.asv_counts
    asv_taxonomy    = agglomerate.out.asv_taxonomy
    filtered_fasta  = agglomerate.out.filtered_fasta
    taxonomy_table  = classification_idtaxa.out.taxonomy_table
}
