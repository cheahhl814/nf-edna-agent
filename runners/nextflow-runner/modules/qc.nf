process trim {
    tag "Trim ${sample_id} [${single_end ? 'SE' : 'PE'}]"
    publishDir "${params.results_dir}/${params.run_id}/qc/trimmed/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads), val(single_end)

    output:
    tuple val(sample_id), path("*.trimmed.fastq.gz"), val(single_end), emit: reads

    script:
    if (single_end) {
        """
        rev_primer_rc=\$(echo "${params.primers_rev}" | tr 'ACGTacgt' 'TGCAtgca' | rev)

        pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
            cutadapt --error-rate 0.1 --times 1 --overlap 3 \
            -j ${task.cpus} -g ${params.primers_fwd} --discard-untrimmed \
            -o ${sample_id}.fwd_trimmed.fastq.gz ${reads}

        # NOTE: --maximum-length intentionally OMITTED. For short-amplicon
        # markers like MiFish-U (170 bp amplicon + 251 bp MiSeq reads),
        # R1+R2 read through the amplicon into the reverse-primer region,
        # producing trimmed reads of ~225 bp. A --maximum-length cap would
        # discard these reads before NGmerge can merge R1+R2 into a
        # consensus. NGmerge (denoise/merge_pairend) enforces length
        # filtering post-merge where it belongs.
        pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
            cutadapt --error-rate 0.1 --times 1 --overlap 3 \
            --minimum-length ${params.min_length} \
            -j ${task.cpus} -a \${rev_primer_rc} \
            -o ${sample_id}.trimmed.fastq.gz ${sample_id}.fwd_trimmed.fastq.gz
        """
    } else {
        """
        pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
            cutadapt --error-rate 0.1 --times 1 --overlap 3 \
            --minimum-length ${params.min_length} \
            -j ${task.cpus} -g ${params.primers_fwd} -G ${params.primers_rev} --discard-untrimmed \
            -o ${sample_id}_R1.trimmed.fastq.gz -p ${sample_id}_R2.trimmed.fastq.gz \
            ${reads[0]} ${reads[1]}
        """
    }
}

process fastqc {
    tag "FastQC ${sample_id}"
    publishDir "${params.results_dir}/${params.run_id}/qc/fastqc/${sample_id}", mode: 'copy', overwrite: false

    input:
    tuple val(sample_id), path(reads), val(single_end)
    tuple val(trim_id), path(trimmed_reads), val(trim_single_end)

    output:
    path "*.zip",  emit: fastqc_zip
    path "*.html", emit: fastqc_html

    script:
    def raw_files     = single_end ? reads.toString() : reads.collect{ it.toString() }.join(' ')
    def trimmed_files = trim_single_end ? trimmed_reads.toString() : trimmed_reads.collect{ it.toString() }.join(' ')
    """
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
        fastqc -t ${task.cpus} ${raw_files}
    pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/qc/pixi.toml \
        fastqc -t ${task.cpus} ${trimmed_files}
    """
}

workflow QC {
    take:
    reads  // tuple(sample_id, reads, single_end)

    main:
    trim(reads)
    fastqc(reads, trim.out.reads)

    emit:
    trimmed_reads = trim.out.reads
    fastqc_zip    = fastqc.out.fastqc_zip
    fastqc_html   = fastqc.out.fastqc_html
}
