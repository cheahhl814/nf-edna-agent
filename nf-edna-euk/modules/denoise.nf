process merge_pairend {
    tag "Merge paired-end reads ${sample_id}"

    input:
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("${sample_id}.merged.fastq.gz"), emit: merged_reads

    script:
    """
    pixi run --manifest-path ${baseDir}/env/denoise/pixi.toml \
        NGmerge -1 ${reads[0]} -2 ${reads[1]} -o ${sample_id}.merged.fastq.gz -z
    """
}

process denoise {
    tag "VSEARCH UNOISE3 ${sample_id}"
    label 'process_low'
    publishDir "${params.results_dir}/${params.run_id}/asv_table/per_sample/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads)

    output:
    tuple val(sample_id), path("${sample_id}.sequences.fasta"), emit: fasta
    tuple val(sample_id), path("${sample_id}.table.biom"),      emit: biom

    script:
    """
    pixi run --manifest-path ${baseDir}/env/denoise/pixi.toml \
        vsearch --fastx_uniques ${reads} --fastaout ${sample_id}.derep.fasta \
        --sizeout --minuniquesize 2 --fastq_ascii 33

    pixi run --manifest-path ${baseDir}/env/denoise/pixi.toml \
        vsearch --cluster_unoise ${sample_id}.derep.fasta \
        --centroids ${sample_id}.sequences.fasta --biomout ${sample_id}.table.biom \
        --minsize 2 --unoise_alpha 2.0
    """
}

process biom2tsv {
    tag "BIOM to TSV ${sample_id}"

    input:
    tuple val(sample_id), path(biom)

    output:
    tuple val(sample_id), path("${sample_id}.table.tsv"), emit: table_tsv

    script:
    """
    pixi run --manifest-path ${baseDir}/env/denoise/pixi.toml \
        biom convert -i ${biom} -o ${sample_id}.table.tsv --to-tsv
    """
}

process merge_denoise {
    tag "Merge denoised outputs"
    publishDir "${params.results_dir}/${params.run_id}/asv_table", mode: 'copy', overwrite: false

    input:
    path tables
    path fastas

    output:
    path "feature-table_renamed.tsv", emit: merged_table
    path "rep-seqs_renamed.fna",      emit: merged_fasta

    script:
    """
    pixi run --manifest-path ${baseDir}/env/denoise/pixi.toml \
        Rscript ${baseDir}/bin/merge_tables.R \
        --input_files ${tables} --output_table feature-table.tsv

    cat ${fastas} > rep-seqs.fna
    awk 'BEGIN{FS=OFS="\\t"} {gsub(/:/,"_",\$1); print}' feature-table.tsv > feature-table_renamed.tsv
    sed '/^>/s/:/_/g' rep-seqs.fna > rep-seqs_renamed.fna
    """
}

process decontam {
    tag "Decontaminate ASV table"
    publishDir "${params.results_dir}/${params.run_id}/asv_table", mode: 'copy', overwrite: false

    input:
    path asv_table
    path rep_seqs
    path metadata

    output:
    path "decontam_asv_table.tsv", emit: table
    path "decontam_rep_seqs.fna",  emit: fasta

    script:
    """
    pixi run --manifest-path ${baseDir}/env/pixi.toml \
        julia ${baseDir}/bin/decontam.jl \
        --asv_table ${asv_table} --metadata ${metadata} \
        --output_table decontam_asv_table.tsv \
        --threshold ${params.decontam_threshold} \
        --neg_col ${params.neg_col} \
        --filter_condition "${params.filter_condition}"

    # Re-filter rep-seqs to match surviving ASVs
    tail -n +2 decontam_asv_table.tsv | awk '{print \$1}' > surviving_ids.txt
    pixi run --manifest-path ${baseDir}/env/classification/pixi.toml \
        seqtk subseq ${rep_seqs} surviving_ids.txt > decontam_rep_seqs.fna
    """
}

workflow DENOISE {
    take:
    reads     // tuple(sample_id, reads, single_end)
    metadata  // path

    main:
    reads
        .branch { sample_id, fastqs, single_end ->
            single: single_end == true
                return tuple(sample_id, fastqs)
            paired: single_end == false
                return tuple(sample_id, fastqs)
        }
        .set { branched }

    merge_pairend(branched.paired)
    denoise_inputs = branched.single.mix(merge_pairend.out.merged_reads)
    denoise(denoise_inputs)
    biom2tsv(denoise.out.biom)

    merge_denoise(
        biom2tsv.out.table_tsv.map { sid, f -> f }.collect(),
        denoise.out.fasta.map { sid, f -> f }.collect()
    )

    decontam(
        merge_denoise.out.merged_table,
        merge_denoise.out.merged_fasta,
        metadata
    )

    emit:
    table = decontam.out.table
    fasta = decontam.out.fasta
}
