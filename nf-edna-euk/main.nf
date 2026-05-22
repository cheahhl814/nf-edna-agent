#!/usr/bin/env nextflow
nextflow.enable.dsl=2

include { QC }          from './modules/qc.nf'
include { DENOISE }     from './modules/denoise.nf'
include { CLASSIFY }    from './modules/classify.nf'
include { DIVERSITY }   from './modules/diversity.nf'
include { ASSOCIATION } from './modules/association.nf'

// ── Input helpers ────────────────────────────────────────────────────────────

def createInputChannel(manifest_path) {
    def manifest_file = file(manifest_path)
    if (!manifest_file.exists()) error "Manifest not found: ${manifest_path}"

    def lines  = manifest_file.readLines()
    def header = lines[0].split(',')
    def is_se  = (header.size() == 2)

    log.info "Manifest: ${manifest_path} | Type: ${is_se ? 'SE' : 'PE'} | Samples: ${lines.size() - 1}"

    if (is_se) {
        return channel.fromPath(manifest_path).splitCsv(header: true)
            .map { row ->
                def f = file(row.'absolute-filepath')
                if (!f.exists()) error "File not found: ${f}"
                tuple(row.'sample-id', f, true)
            }
    } else {
        return channel.fromPath(manifest_path).splitCsv(header: true)
            .map { row ->
                def r1 = file(row.'read1-filepath')
                def r2 = file(row.'read2-filepath')
                if (!r1.exists()) error "R1 not found: ${r1}"
                if (!r2.exists()) error "R2 not found: ${r2}"
                tuple(row.'sample-id', [r1, r2], false)
            }
    }
}

// ── State writer ─────────────────────────────────────────────────────────────

process WRITE_STATE {
    publishDir "${params.results_dir}/${params.run_id}", mode: 'copy', overwrite: true

    input:
    val stages
    val last_stage

    output:
    path "pipeline_state.json"

    exec:
    def stageList = stages
    def outputs = [:]
    if ('qc' in stageList)
        outputs.trimmed_reads = "${params.results_dir}/${params.run_id}/qc/trimmed/"
    if ('denoise' in stageList) {
        outputs.asv_table = "${params.results_dir}/${params.run_id}/asv_table/feature-table_renamed.tsv"
        outputs.rep_seqs  = "${params.results_dir}/${params.run_id}/asv_table/rep-seqs_renamed.fna"
    }
    if ('classify' in stageList) {
        outputs.taxonomy  = "${params.results_dir}/${params.run_id}/taxonomy/idtaxa_classification_confident.tsv"
        outputs.asv_counts = "${params.results_dir}/${params.run_id}/taxonomy/agglomerated_data/asv_counts.tsv"
    }
    if ('diversity' in stageList)
        outputs.diversity = "${params.results_dir}/${params.run_id}/diversity/"
    if ('association' in stageList)
        outputs.association = "${params.results_dir}/${params.run_id}/association/"

    def state = [
        run_id           : params.run_id,
        pipeline         : "nf-edna-euk",
        marker           : params.marker ?: "18S-V9",
        completed_stages : stageList,
        last_stage       : last_stage,
        params_used      : [
            primers_fwd : params.primers_fwd,
            primers_rev : params.primers_rev,
            min_length  : params.min_length,
            max_length  : params.max_length,
            kingdoms    : params.kingdoms
        ],
        outputs : outputs
    ]

    def json = groovy.json.JsonOutput.prettyPrint(
        groovy.json.JsonOutput.toJson(state)
    )
    task.workDir.resolve("pipeline_state.json").text = json
}

// ── Named workflow entry points ───────────────────────────────────────────────

workflow QC_ONLY {
    reads = createInputChannel(params.input_manifest)
    QC(reads)
    WRITE_STATE(channel.value(['qc']), channel.value('qc'))
}

workflow DENOISE_ONLY {
    reads    = createInputChannel(params.input_manifest)
    metadata = channel.fromPath(params.metadata)
    QC(reads)
    DENOISE(QC.out.trimmed_reads, metadata)
    WRITE_STATE(channel.value(['qc', 'denoise']), channel.value('denoise'))
}

workflow CLASSIFY_ONLY {
    reads        = createInputChannel(params.input_manifest)
    metadata     = channel.fromPath(params.metadata)
    idtaxa_model = channel.fromPath(params.idtaxa_model)
    QC(reads)
    DENOISE(QC.out.trimmed_reads, metadata)
    CLASSIFY(
        DENOISE.out.table,
        DENOISE.out.fasta,
        idtaxa_model,
        metadata
    )
    WRITE_STATE(channel.value(['qc', 'denoise', 'classify']), channel.value('classify'))
}

workflow DIVERSITY_ONLY {
    reads        = createInputChannel(params.input_manifest)
    metadata     = channel.fromPath(params.metadata)
    idtaxa_model = channel.fromPath(params.idtaxa_model)
    QC(reads)
    DENOISE(QC.out.trimmed_reads, metadata)
    CLASSIFY(DENOISE.out.table, DENOISE.out.fasta, idtaxa_model, metadata)
    DIVERSITY(
        CLASSIFY.out.filtered_fasta,
        CLASSIFY.out.asv_counts,
        CLASSIFY.out.asv_taxonomy,
        metadata
    )
    WRITE_STATE(channel.value(['qc', 'denoise', 'classify', 'diversity']), channel.value('diversity'))
}

workflow {
    reads        = createInputChannel(params.input_manifest)
    metadata     = channel.fromPath(params.metadata)
    idtaxa_model = channel.fromPath(params.idtaxa_model)

    QC(reads)
    DENOISE(QC.out.trimmed_reads, metadata)
    CLASSIFY(DENOISE.out.table, DENOISE.out.fasta, idtaxa_model, metadata)
    DIVERSITY(
        CLASSIFY.out.filtered_fasta,
        CLASSIFY.out.asv_counts,
        CLASSIFY.out.asv_taxonomy,
        metadata
    )
    ASSOCIATION(
        CLASSIFY.out.asv_counts,
        CLASSIFY.out.asv_taxonomy,
        metadata,
        DIVERSITY.out.alpha_diversity_metrics
    )
    WRITE_STATE(
        channel.value(['qc', 'denoise', 'classify', 'diversity', 'association']),
        channel.value('association')
    )
}
