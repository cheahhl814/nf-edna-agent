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
        Rscript ${baseDir}/bin/idtaxa_rds.R \
        --query_sequences ${rep_seqs_fna} --idtaxa_model ${idtaxa_model} \
        --output_classification idtaxa_classification.tsv \
        --output_confidence idtaxa_confidence.tsv

    pixi run --manifest-path ${baseDir}/env/pixi.toml \
        julia ${baseDir}/bin/filter_idtaxa_by_confidence.jl \
        --classification_file idtaxa_classification.tsv \
        --confidence_file idtaxa_confidence.tsv \
        --output_file idtaxa_classification_confident.tsv \
        --threshold ${params.idtaxa_threshold}
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
    path "agglomerated_data/asv_counts.tsv",      emit: asv_counts
    path "agglomerated_data/asv_taxonomy.tsv",    emit: asv_taxonomy
    path "agglomerated_data/genus_counts.tsv",    emit: genus_counts
    path "agglomerated_data/genus_taxonomy.tsv"
    path "agglomerated_data/phylum_counts.tsv",   optional: true
    path "agglomerated_data/phylum_taxonomy.tsv", optional: true
    path "agglomerated_data/class_counts.tsv",    optional: true
    path "agglomerated_data/class_taxonomy.tsv",  optional: true
    path "agglomerated_data/family_counts.tsv",   optional: true
    path "agglomerated_data/family_taxonomy.tsv", optional: true
    path "agglomerated_data/species_counts.tsv",  optional: true
    path "agglomerated_data/species_taxonomy.tsv", optional: true
    path "filtered_asvs.fna",                     emit: filtered_fasta

    script:
    """
    pixi run --manifest-path ${baseDir}/env/classification/pixi.toml \
        Rscript ${baseDir}/bin/agglomerate_data.R \
        --asv_counts_file ${asv_counts} --taxonomy_file ${taxonomy_table} \
        --metadata_file ${metadata} --output_dir agglomerated_data \
        --kingdoms ${params.kingdoms} --ranks ${params.target_ranks}

    tail -n +2 agglomerated_data/asv_counts.tsv | awk '{print \$1}' > asv_ids_to_keep.txt
    sed 's/;size=[0-9]*//' ${asv_fasta} > rep_seqs_clean.fna
    pixi run --manifest-path ${baseDir}/env/classification/pixi.toml \
        seqtk subseq rep_seqs_clean.fna asv_ids_to_keep.txt > filtered_asvs.fna
    """
}

process geocurate {
    tag "Geographic concordance filtering"
    publishDir "${params.results_dir}/${params.run_id}/taxonomy/geocurate", mode: 'copy', overwrite: false

    input:
    path asv_taxonomy

    output:
    path "geocurated_asv_taxonomy.tsv", emit: asv_taxonomy
    path "concordant_taxa.txt",         emit: concordant
    path "discordant_taxa.txt",         emit: discordant
    path "norecords_taxa.txt",          emit: norecords
    path "occurrence_cache",            emit: cache

    script:
    """
    # Extract unique species names from the species column (skip NA/unassigned)
    spec_col=\$(head -1 ${asv_taxonomy} | tr '\t' '\n' | grep -nx "^species\$" | cut -d: -f1)
    awk -v col=\$spec_col 'BEGIN{FS="\t"} NR>1 && \$col!="" && \$col!="NA" && \$col!="unassigned" {print \$col}' \
        ${asv_taxonomy} | sort -u > taxa_list.txt

    # Fetch occurrence data from GBIF and OBIS
    pixi run --manifest-path ${baseDir}/env/geocuration/pixi.toml \
        Rscript ${baseDir}/bin/geocurate_fetch.R \
        --taxa taxa_list.txt \
        --cache_dir occurrence_cache

    # Check geographic concordance
    pixi run --manifest-path ${baseDir}/env/geocuration/pixi.toml \
        Rscript ${baseDir}/bin/geocurate_check.R \
        --taxa taxa_list.txt \
        --coords ${params.geocurate_coords} \
        --buffer ${params.geocurate_buffer} \
        --cache_dir occurrence_cache \
        --concordant concordant_taxa.txt \
        --discordant discordant_taxa.txt \
        --norecords norecords_taxa.txt

    # Keep concordant + norecords; discard discordant
    cat concordant_taxa.txt norecords_taxa.txt > curated_species.txt
    head -1 ${asv_taxonomy} > geocurated_asv_taxonomy.tsv
    awk -v col=\$spec_col 'BEGIN{FS=OFS="\t"} NR==FNR{keep[\$0]=1; next} FNR>1 && \$col in keep' \
        curated_species.txt ${asv_taxonomy} >> geocurated_asv_taxonomy.tsv || true
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

    if (params.geocurate) {
        geocurate(agglomerate.out.asv_taxonomy)
        final_taxonomy = geocurate.out.asv_taxonomy
    } else {
        final_taxonomy = agglomerate.out.asv_taxonomy
    }

    emit:
    asv_counts      = agglomerate.out.asv_counts
    asv_taxonomy    = final_taxonomy
    filtered_fasta  = agglomerate.out.filtered_fasta
    taxonomy_table  = classification_idtaxa.out.taxonomy_table
}
