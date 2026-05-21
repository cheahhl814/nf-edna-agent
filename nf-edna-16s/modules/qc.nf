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
        pixi run --manifest-path ${baseDir}/env/qc/pixi.toml \
            cutadapt --error-rate 0.1 --times 1 --overlap 3 \
            --minimum-length ${params.min_length} --maximum-length ${params.max_length} \
            -j ${task.cpus} -g ${params.primers_fwd} --discard-untrimmed \
            -o ${sample_id}.trimmed.fastq.gz ${reads}
        """
    } else {
        """
        pixi run --manifest-path ${baseDir}/env/qc/pixi.toml \
            cutadapt --error-rate 0.1 --times 1 --overlap 3 \
            --minimum-length ${params.min_length} --maximum-length ${params.max_length} \
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
    pixi run --manifest-path ${baseDir}/env/qc/pixi.toml \
        fastqc -t ${task.cpus} ${raw_files}
    pixi run --manifest-path ${baseDir}/env/qc/pixi.toml \
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
