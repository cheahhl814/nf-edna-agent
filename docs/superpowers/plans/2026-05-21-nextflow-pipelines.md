# Nextflow Pipelines Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `nf-edna-16s` and `nf-edna-euk` — two independently runnable Nextflow pipelines sharing the same subworkflow names and `pipeline_state.json` output contract, adapted from the existing `nf-emplicon` pipeline.

**Architecture:** Each pipeline is a Nextflow DSL2 project with named workflows (`QC`, `DENOISE`, `CLASSIFY`, `DIVERSITY`, `ASSOCIATION`, and a default `FULL`) selectable via Nextflow's `-entry` flag. A `WRITE_STATE` process at the end of each named workflow writes `pipeline_state.json` to `results/{run_id}/` — this file is the contract the Claude Code skills read. Both pipelines share identical module names and output directory structures; they differ only in parameter defaults, kingdom filters, and marker-gene-specific length ranges.

**Tech Stack:** Nextflow DSL2 ≥24.04, Pixi (environment management), VSEARCH (denoising), Cutadapt (trimming), NGmerge (PE merging), DECIPHER/IdTaxa (classification), R (diversity + association), Julia (filtering + decontam), FastQC, MAFFT, FastTree, Maaslin2

---

> **Note on entry points:** This plan uses Nextflow's native `-entry <WORKFLOW_NAME>` flag (single dash) to select named workflows. The design spec used `--entry` (double dash, a params approach) — `-entry` is preferred as it's a first-class DSL2 concept and avoids runtime `if/switch` dispatch.

> **Note on script reuse:** `bin/` and `env/` contain large R/Julia scripts and Pixi environments. Both pipelines symlink these from `nf-emplicon` during development to avoid duplication. The symlink is acceptable because both pipelines live in the same repo. If deployed independently, copy and decouple.

---

## File Map

**Created:**
```
AMPLICON/
├── nf-edna-16s/
│   ├── main.nf                     # Named workflows + WRITE_STATE
│   ├── nextflow.config             # 16S parameter defaults
│   ├── modules/
│   │   ├── qc.nf                   # Trim + FastQC (adapted from nf-emplicon)
│   │   ├── denoise.nf              # Merge + VSEARCH + decontam (adapted)
│   │   ├── classify.nf             # IDTAXA + agglomerate (adapted, renamed)
│   │   ├── diversity.nf            # Tree + alpha + beta (adapted)
│   │   └── association.nf          # DAA + correlation (adapted)
│   ├── bin -> ../nf-emplicon/bin   # Symlink
│   ├── env -> ../nf-emplicon/env   # Symlink
│   └── tests/
│       ├── create_test_data.py     # Generates synthetic 16S FASTQs
│       ├── train_test_model.sh     # Trains minimal IDTAXA model
│       ├── params_test.json        # Test run parameters
│       ├── fixtures/               # Synthetic FASTQs, manifest, metadata
│       └── expected_outputs/       # Reference files for pass/fail checks
├── nf-edna-euk/                    # Same structure, eukaryote-specific
│   ├── main.nf
│   ├── nextflow.config             # Eukaryote defaults (kingdoms, length ranges)
│   ├── modules/ (same names)
│   ├── bin -> ../nf-emplicon/bin
│   ├── env -> ../nf-emplicon/env
│   └── tests/
│       ├── create_test_data.py     # Generates synthetic 18S V9 FASTQs
│       ├── train_test_model.sh
│       ├── params_test.json
│       ├── fixtures/
│       └── expected_outputs/
└── tests/                          # Shared fixtures for skills (Plan 2)
    └── fixtures/
        ├── pipeline_state_16s_intake.json
        ├── pipeline_state_16s_qc.json
        ├── pipeline_state_16s_classify.json
        ├── pipeline_state_16s_full.json
        ├── pipeline_state_euk_intake.json
        └── pipeline_state_euk_full.json
```

---

## Task 1: Scaffold nf-edna-16s directory

**Files:**
- Create: `nf-edna-16s/` (directory tree + symlinks)

- [ ] **Step 1: Create directory structure and symlinks**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
mkdir -p nf-edna-16s/modules
mkdir -p nf-edna-16s/tests/fixtures
mkdir -p nf-edna-16s/tests/expected_outputs
ln -s ../nf-emplicon/bin nf-edna-16s/bin
ln -s ../nf-emplicon/env nf-edna-16s/env
```

- [ ] **Step 2: Verify symlinks resolve correctly**

```bash
ls -la nf-edna-16s/bin/ | head -5
ls -la nf-edna-16s/env/
```

Expected: R scripts visible through `bin/`, `qc/`, `denoise/`, etc. visible through `env/`.

- [ ] **Step 3: Commit scaffold**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/
git commit -m "feat: scaffold nf-edna-16s directory structure"
```

---

## Task 2: Write nf-edna-16s/nextflow.config

**Files:**
- Create: `nf-edna-16s/nextflow.config`

- [ ] **Step 1: Write the config**

Create `nf-edna-16s/nextflow.config`:

```groovy
manifest {
    name            = 'nf-edna-16s'
    author          = 'Cheah Hong Leong'
    description     = 'eDNA metabarcoding pipeline for 16S prokaryotes'
    mainScript      = 'main.nf'
    nextflowVersion = '!>=24.04.0'
    version         = '1.0.0'
}

params {
    // Run identity
    run_id          = "16s-${new java.util.Date().format('yyyyMMdd-HHmmss')}"
    results_dir     = "${launchDir}/results"

    // Inputs
    input_manifest  = ""
    metadata        = ""
    idtaxa_model    = ""

    // 16S-specific defaults (V3-V4)
    primers_fwd     = ""
    primers_rev     = ""
    min_length      = 350
    max_length      = 550
    kingdoms        = "Bacteria,Archaea"

    // Decontam
    decontam_threshold  = 0.1
    neg_col             = "is_negative"
    filter_condition    = "is_negative == false"

    // Diversity
    grouping_variable           = ""
    distance_metric             = "bray"
    clustering_method           = "ward.D2"
    num_clusters                = ""
    metadata_numeric_variables  = ""

    // Association
    reference_level     = ""
    daa_level           = "Genus"
    correlation_level   = "Genus"
    target_ranks        = "Phylum,Family,Genus"
}

process {
    cpus   = { check_max(1 * task.attempt, 'cpus') }
    memory = { check_max(6.GB * task.attempt, 'memory') }
    time   = { check_max(4.h * task.attempt, 'time') }

    errorStrategy = { task.exitStatus in [143, 137, 104, 134, 139] ? 'retry' : 'finish' }
    maxRetries    = 2

    withLabel: process_low {
        cpus   = { check_max(4 * task.attempt, 'cpus') }
        memory = { check_max(12.GB * task.attempt, 'memory') }
        time   = { check_max(4.h * task.attempt, 'time') }
    }
    withLabel: process_medium {
        cpus   = { check_max(8 * task.attempt, 'cpus') }
        memory = { check_max(36.GB * task.attempt, 'memory') }
        time   = { check_max(8.h * task.attempt, 'time') }
    }
}

def check_max(obj, type) {
    if (type == 'memory') {
        try { if (obj.compareTo(params.max_memory as nextflow.util.MemoryUnit) == 1) return params.max_memory as nextflow.util.MemoryUnit
              else return obj } catch (all) { return obj }
    } else if (type == 'time') {
        try { if (obj.compareTo(params.max_time as nextflow.util.Duration) == 1) return params.max_time as nextflow.util.Duration
              else return obj } catch (all) { return obj }
    } else if (type == 'cpus') {
        try { return Math.min(obj, params.max_cpus as int) } catch (all) { return obj }
    }
}

params.max_memory = '128.GB'
params.max_cpus   = 16
params.max_time   = '240.h'
```

- [ ] **Step 2: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/nextflow.config
git commit -m "feat: add nf-edna-16s nextflow config with 16S defaults"
```

---

## Task 3: Write nf-edna-16s/modules/qc.nf

**Files:**
- Create: `nf-edna-16s/modules/qc.nf`

Adapted from `nf-emplicon/modules/qc.nf`. Changes: `publishDir` uses `run_id`; parameter names updated (`primer_f` → `primers_fwd`, `primer_r` → `primers_rev`; adapters removed since cutadapt will use linked adapters mode); min_length passed via params.

- [ ] **Step 1: Write the module**

Create `nf-edna-16s/modules/qc.nf`:

```groovy
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
```

- [ ] **Step 2: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/modules/qc.nf
git commit -m "feat: add nf-edna-16s QC module"
```

---

## Task 4: Write nf-edna-16s/modules/denoise.nf

**Files:**
- Create: `nf-edna-16s/modules/denoise.nf`

Adapted from `nf-emplicon/modules/denoise.nf`. Changes: `publishDir` updated; decontam (from `nf-emplicon/modules/decontam.nf`) folded in as a process at the end of this workflow since it operates on the ASV table immediately after denoising.

- [ ] **Step 1: Write the module**

Create `nf-edna-16s/modules/denoise.nf`:

```groovy
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
        --input_files ${tables.join(' ')} --output_table feature-table.tsv

    cat ${fastas.join(' ')} > rep-seqs.fna
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
```

- [ ] **Step 2: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/modules/denoise.nf
git commit -m "feat: add nf-edna-16s DENOISE module (includes decontam)"
```

---

## Task 5: Write nf-edna-16s/modules/classify.nf

**Files:**
- Create: `nf-edna-16s/modules/classify.nf`

Adapted from `nf-emplicon/modules/classification.nf`. Renamed file and workflow. `publishDir` updated to use `run_id`.

- [ ] **Step 1: Write the module**

Create `nf-edna-16s/modules/classify.nf`:

```groovy
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
```

- [ ] **Step 2: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/modules/classify.nf
git commit -m "feat: add nf-edna-16s CLASSIFY module"
```

---

## Task 6: Write nf-edna-16s/modules/diversity.nf

**Files:**
- Create: `nf-edna-16s/modules/diversity.nf`

Adapted from `nf-emplicon/modules/diversity.nf`. `publishDir` updated.

- [ ] **Step 1: Write the module**

Create `nf-edna-16s/modules/diversity.nf`:

```groovy
process tree {
    tag "Phylogenetic tree"
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
    path "tse_object.rds",       emit: tse
    path "community_typing.rds", emit: community_rds
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
    tree                   = tree.out.tree
    alpha_diversity_metrics = alpha_diversity.out.alpha_diversity_metrics
    tse                    = beta_diversity.out.tse
}
```

- [ ] **Step 2: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/modules/diversity.nf
git commit -m "feat: add nf-edna-16s DIVERSITY module"
```

---

## Task 7: Write nf-edna-16s/modules/association.nf

**Files:**
- Create: `nf-edna-16s/modules/association.nf`

Adapted from `nf-emplicon/modules/association.nf`. `publishDir` updated.

- [ ] **Step 1: Write the module**

Create `nf-edna-16s/modules/association.nf`:

```groovy
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
        --top_n_taxa_plot 20 --reference_level "${params.reference_level}"
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
    pixi run --manifest-path ${baseDir}/env/association/pixi.toml \
        Rscript ${baseDir}/bin/correlation_analysis.R \
        --input_asv_counts ${asv_counts} --input_asv_taxonomy ${asv_taxonomy} \
        --input_metadata ${metadata} --input_alpha_diversity ${alpha_diversity} \
        --fixed_effect_variable "${params.grouping_variable}" \
        --metadata_numeric_variables "${params.metadata_numeric_variables}" \
        --level_to_analyze "${params.correlation_level}" --output_dir .
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
```

- [ ] **Step 2: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/modules/association.nf
git commit -m "feat: add nf-edna-16s ASSOCIATION module"
```

---

## Task 8: Write nf-edna-16s/main.nf

**Files:**
- Create: `nf-edna-16s/main.nf`

This is the core addition over nf-emplicon: named workflow entry points selectable via `-entry`, and a `WRITE_STATE` process that writes `pipeline_state.json` at the end of each named workflow.

- [ ] **Step 1: Write main.nf**

Create `nf-edna-16s/main.nf`:

```groovy
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
    val completed_stages
    val last_stage

    output:
    path "pipeline_state.json"

    exec:
    def outputs = [:]
    if ('qc' in completed_stages)
        outputs.trimmed_reads = "${params.results_dir}/${params.run_id}/qc/trimmed/"
    if ('denoise' in completed_stages) {
        outputs.asv_table = "${params.results_dir}/${params.run_id}/asv_table/feature-table_renamed.tsv"
        outputs.rep_seqs  = "${params.results_dir}/${params.run_id}/asv_table/rep-seqs_renamed.fna"
    }
    if ('classify' in completed_stages) {
        outputs.taxonomy  = "${params.results_dir}/${params.run_id}/taxonomy/idtaxa_classification_confident.tsv"
        outputs.asv_counts = "${params.results_dir}/${params.run_id}/taxonomy/agglomerated_data/asv_counts.tsv"
    }
    if ('diversity' in completed_stages)
        outputs.diversity = "${params.results_dir}/${params.run_id}/diversity/"
    if ('association' in completed_stages)
        outputs.association = "${params.results_dir}/${params.run_id}/association/"

    def state = [
        run_id           : params.run_id,
        pipeline         : "nf-edna-16s",
        marker           : "16S",
        completed_stages : completed_stages,
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
    reads       = createInputChannel(params.input_manifest)
    metadata    = channel.fromPath(params.metadata)
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
```

> **Note:** The `-entry` flag in Nextflow selects a named workflow. `workflow {}` (no name) is the default. To run only QC: `nextflow run nf-edna-16s -entry QC_ONLY`. Named workflows here use `_ONLY` suffix to avoid collision with the imported module workflow names (`QC`, `DENOISE`, etc.).

- [ ] **Step 2: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/main.nf
git commit -m "feat: add nf-edna-16s main.nf with named entry points and WRITE_STATE"
```

---

## Task 9: Create synthetic 16S test data

**Files:**
- Create: `nf-edna-16s/tests/create_test_data.py`
- Create: `nf-edna-16s/tests/train_test_model.sh`
- Create: `nf-edna-16s/tests/params_test.json`
- Create: `nf-edna-16s/tests/fixtures/manifest.csv`
- Create: `nf-edna-16s/tests/fixtures/metadata.tsv`

- [ ] **Step 1: Write the FASTQ generator**

Create `nf-edna-16s/tests/create_test_data.py`:

```python
#!/usr/bin/env python3
"""
Generate synthetic 16S V3-V4 FASTQs for pipeline testing.
Produces 3 samples × 200 reads each. Sequences are real 16S V3-V4 amplicons
flanked by standard 341F/806R primers, with simulated Phred33 quality scores.
"""
import gzip, random, pathlib, textwrap

random.seed(42)

# 341F/806R primers (V3-V4)
PRIMER_F = "CCTACGGGNGGCWGCAG"
PRIMER_R = "GACTACNVGGGTWTCTAATCC"

# Six synthetic 16S V3-V4 core sequences (amplicon only, without primers)
# Derived from representative SILVA sequences
CORE_SEQS = [
    "TAGGGAATCTTCCGCAATGGACGAAAGTCTGACGGAGCAACGCCGCGTGAGTGATGAAGGTTTTCGGATCGTAAAGCTCTGTTGTAAGGGAAGAACAAGTACCGTTCGAATAGGGCGGTACCTTGACGGTACCTTATGAGAAAGCCACGGCTAACTACGTGCCAGCAGCCGCGGTAATACGTAGGTGGCAAGCGTTGTCC",
    "TACGGAGGGTGCAAGCGTTAATCGGAATTACTGGGCGTAAAGCGCACGCAGGCGGTTTGTTAAGTCAGATGTGAAATCCCCGGGCTCAACCTGGGAACTGCATTTGAAACTGGCAAGCTTGAGTCTCGTAGAGGGGGGTAGAATTCCAGGTGTAGCGGTGAAATGCGTAGAGATCTGGAGGAATACCGGTGGCGAAGG",
    "TACGTATGGAGCAAGCGTTATCCGGATTTACTGGGTGTAAAGGGAGCGCAGGCGGTACGGCAAGTCTGATGTGAAAGCCCGGGGCTCAACCCCGGAATTGCATTGGAAACTGTCGTACTTGAGTGCAGGAGAGGTAAGCGGAATTCCTAGTGTAGCGGTGAAATGCGTAGATATTAGGAGGAACACCAGTGGCGAAGGC",
    "TACGTAGGTCCCGAGCGTTGTCCGGATTTATTGGGCGTAAAGCGAGCGCAGGCGGTTTGATAAGTCTGAAGTTAAAGGCTGTGGCTTAACCATAGTACGCTTTGGAAACTGTCAAACTTGAGTGCAGAAGGGGAGAGTGGAATTCCATGTGTAGCGGTGAAATGCGTAGATATATGGAGGAACACCGGTGGCGAAAGCG",
    "TACGTATGTCACAAGCGTTGTCCGGATTTATTGGGCGTAAAGGGAGCGCAGGCGGTTTAATAAGTCTGATGTGAAAGCCCGGGGCTCAACCCCGGAATTGCATTGGAAACTGTTTAACTTGAGTGCAGAAGGGGAGAGTGGAATTCCATGTGTAGCGGTGAAATGCGTAGATATATGGAGGAACACCGGTGGCGAAAGCG",
    "TACGGAGGATCCGAGCGTTATCCGGATTTATTGGGTTTAAAGGGTGCGTAGGCGGATTATCAAGTCAGCGGTAAAATTTCGGGGCTCAACCCCGAAACTGCCGTTGATACTGATAGTCTTGAGTATGGAAGAGGTGAGTGGAATTCCGAGTGTAGAGGTGAAATTCGTAGATATTCGGAGGAACACCAGTGGCGAAGGCG",
]

SAMPLES = ["sample1", "sample2", "sample3"]
READS_PER_SAMPLE = 200
OUTPUT_DIR = pathlib.Path(__file__).parent / "fixtures"
OUTPUT_DIR.mkdir(exist_ok=True)

def make_quality(length, mean_q=35, min_q=20):
    """Simulate Phred33 quality string."""
    qs = [min(40, max(min_q, int(random.gauss(mean_q, 3)))) for _ in range(length)]
    return "".join(chr(q + 33) for q in qs)

def make_read(seq_core, sample_idx):
    full_seq = PRIMER_F + seq_core + PRIMER_R
    # Introduce ~0.5% sequencing errors
    seq = list(full_seq)
    for i in range(len(seq)):
        if random.random() < 0.005:
            seq[i] = random.choice("ACGT")
    seq = "".join(seq)
    qual = make_quality(len(seq))
    return seq, qual

manifest_rows = []
for s_idx, sample in enumerate(SAMPLES):
    out_file = OUTPUT_DIR / f"{sample}.fastq.gz"
    with gzip.open(out_file, "wt") as fh:
        for i in range(READS_PER_SAMPLE):
            core = random.choice(CORE_SEQS)
            seq, qual = make_read(core, s_idx)
            fh.write(f"@{sample}_read{i+1}\n{seq}\n+\n{qual}\n")
    manifest_rows.append(f"{sample},{out_file.resolve()}")
    print(f"Generated {out_file} ({READS_PER_SAMPLE} reads)")

# Manifest
manifest_path = OUTPUT_DIR / "manifest.csv"
manifest_path.write_text("sample-id,absolute-filepath\n" + "\n".join(manifest_rows) + "\n")
print(f"Manifest: {manifest_path}")

# Metadata
metadata_path = OUTPUT_DIR / "metadata.tsv"
metadata_path.write_text(
    "sample-id\ttreatment\tis_negative\n"
    "sample1\tcontrol\tFALSE\n"
    "sample2\ttreated\tFALSE\n"
    "sample3\tcontrol\tFALSE\n"
)
print(f"Metadata: {metadata_path}")

# Reference FASTA for IDTAXA training (same sequences, with taxonomy headers)
TAXA = [
    "Root;Bacteria;Proteobacteria;Gammaproteobacteria;Pseudomonadales;Pseudomonadaceae;Pseudomonas",
    "Root;Bacteria;Firmicutes;Bacilli;Lactobacillales;Streptococcaceae;Streptococcus",
    "Root;Bacteria;Actinobacteria;Actinobacteria;Corynebacteriales;Corynebacteriaceae;Corynebacterium",
    "Root;Bacteria;Proteobacteria;Betaproteobacteria;Burkholderiales;Burkholderiaceae;Burkholderia",
    "Root;Bacteria;Bacteroidetes;Bacteroidia;Bacteroidales;Bacteroidaceae;Bacteroides",
    "Root;Bacteria;Firmicutes;Bacilli;Bacillales;Bacillaceae;Bacillus",
]
ref_path = OUTPUT_DIR / "reference_16s.fasta"
with ref_path.open("w") as fh:
    for i, (seq, tax) in enumerate(zip(CORE_SEQS, TAXA)):
        fh.write(f">{tax}\n{PRIMER_F}{seq}{PRIMER_R}\n")
print(f"Reference FASTA: {ref_path}")
```

- [ ] **Step 2: Write the model training script**

Create `nf-edna-16s/tests/train_test_model.sh`:

```bash
#!/usr/bin/env bash
# Train a minimal IDTAXA model on the synthetic reference sequences.
# Run once before tests. Requires nf-emplicon env to be available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_FASTA="${SCRIPT_DIR}/fixtures/reference_16s.fasta"
MODEL_OUT="${SCRIPT_DIR}/fixtures/idtaxa_model_16s.rds"
BIN_DIR="${SCRIPT_DIR}/../bin"
ENV_DIR="${SCRIPT_DIR}/../env"

if [[ ! -f "${REF_FASTA}" ]]; then
    echo "Reference FASTA not found. Run create_test_data.py first."
    exit 1
fi

pixi run --manifest-path "${ENV_DIR}/classification/pixi.toml" \
    Rscript "${BIN_DIR}/train_idtaxa_model.R" \
    --reference_fasta "${REF_FASTA}" \
    --output_model "${MODEL_OUT}" \
    --min_len 50 --max_len 600

echo "Model written to: ${MODEL_OUT}"
```

- [ ] **Step 3: Write params_test.json**

Create `nf-edna-16s/tests/params_test.json`:

```json
{
  "run_id": "test-16s-run",
  "results_dir": "/tmp/nf-edna-16s-test-results",
  "input_manifest": "tests/fixtures/manifest.csv",
  "metadata": "tests/fixtures/metadata.tsv",
  "idtaxa_model": "tests/fixtures/idtaxa_model_16s.rds",
  "primers_fwd": "CCTACGGGNGGCWGCAG",
  "primers_rev": "GACTACNVGGGTWTCTAATCC",
  "min_length": 200,
  "max_length": 600,
  "kingdoms": "Bacteria,Archaea",
  "grouping_variable": "treatment",
  "reference_level": "control",
  "daa_level": "Genus",
  "correlation_level": "Genus",
  "decontam_threshold": 0.1,
  "neg_col": "is_negative",
  "filter_condition": "is_negative == false",
  "num_clusters": "2",
  "metadata_numeric_variables": ""
}
```

- [ ] **Step 4: Generate test data and train model**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON/nf-edna-16s
python3 tests/create_test_data.py
bash tests/train_test_model.sh
```

Expected: `tests/fixtures/` contains `sample1.fastq.gz`, `sample2.fastq.gz`, `sample3.fastq.gz`, `manifest.csv`, `metadata.tsv`, `reference_16s.fasta`, `idtaxa_model_16s.rds`.

- [ ] **Step 5: Commit test infrastructure**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-16s/tests/
git commit -m "feat: add nf-edna-16s test data generator and model trainer"
```

---

## Task 10: Test nf-edna-16s QC entry point

**Files:** none created — this is a test run.

- [ ] **Step 1: Run QC entry point**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON/nf-edna-16s
nextflow run . -entry QC_ONLY -params-file tests/params_test.json
```

- [ ] **Step 2: Verify outputs**

```bash
ls /tmp/nf-edna-16s-test-results/test-16s-run/qc/trimmed/
ls /tmp/nf-edna-16s-test-results/test-16s-run/qc/fastqc/
cat /tmp/nf-edna-16s-test-results/test-16s-run/pipeline_state.json
```

Expected:
- Trimmed FASTQ files present for each sample
- FastQC `.html` and `.zip` files present
- `pipeline_state.json` contains `"completed_stages": ["qc"]` and `"last_stage": "qc"`

- [ ] **Step 3: If QC fails — diagnose**

```bash
cat .nextflow.log | grep -A5 "ERROR\|FAILED"
```

Common causes:
- Primer sequence not found in reads → check primer orientation in `params_test.json`
- `pixi` not found → confirm pixi is installed and `env/qc/pixi.toml` exists via symlink

---

## Task 11: Test nf-edna-16s FULL pipeline

- [ ] **Step 1: Run full pipeline**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON/nf-edna-16s
nextflow run . -params-file tests/params_test.json
```

- [ ] **Step 2: Verify all stage outputs and state file**

```bash
RESULTS=/tmp/nf-edna-16s-test-results/test-16s-run

# Check each stage directory
for dir in qc asv_table taxonomy diversity association; do
    echo "--- $dir ---"
    ls "$RESULTS/$dir/" 2>/dev/null || echo "MISSING"
done

# Verify state file
python3 -c "
import json
with open('$RESULTS/pipeline_state.json') as f:
    s = json.load(f)
expected = ['qc', 'denoise', 'classify', 'diversity', 'association']
assert s['completed_stages'] == expected, f'Got: {s[\"completed_stages\"]}'
assert s['last_stage'] == 'association'
assert s['pipeline'] == 'nf-edna-16s'
print('pipeline_state.json: OK')
"

# Check taxonomy output contains known taxa
grep -i "Pseudomonas\|Streptococcus\|Bacillus" \
    "$RESULTS/taxonomy/idtaxa_classification_confident.tsv" \
    && echo "Taxonomy: known taxa found" || echo "WARNING: no known taxa found"
```

- [ ] **Step 3: If full pipeline passes, commit a test-run log**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
cp nf-edna-16s/.nextflow.log nf-edna-16s/tests/last_test_run.log 2>/dev/null || true
git add nf-edna-16s/tests/last_test_run.log
git commit -m "test: record passing nf-edna-16s full pipeline run"
```

---

## Task 12: Scaffold nf-edna-euk from nf-edna-16s

**Files:**
- Create: `nf-edna-euk/` (directory tree + all modules + config)

The eukaryote pipeline is structurally identical to `nf-edna-16s`. The differences are in `nextflow.config` (different defaults), `modules/classify.nf` (different kingdoms filter, no change needed — kingdoms comes from params), and `main.nf` (pipeline name in state). All modules are functionally identical; only `nextflow.config` and `main.nf` need changes.

- [ ] **Step 1: Copy nf-edna-16s to nf-edna-euk**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
cp -r nf-edna-16s nf-edna-euk
# Remove symlinks and re-create (they'd still point correctly but let's be explicit)
rm nf-edna-euk/bin nf-edna-euk/env
ln -s ../nf-emplicon/bin nf-edna-euk/bin
ln -s ../nf-emplicon/env nf-edna-euk/env
# Clear test fixtures — eukaryote test data is different
rm -rf nf-edna-euk/tests/fixtures/*
rm -f nf-edna-euk/tests/last_test_run.log
```

- [ ] **Step 2: Update nf-edna-euk/nextflow.config for eukaryote defaults**

In `nf-edna-euk/nextflow.config`, change the following lines (all others stay the same):

```groovy
    name        = 'nf-edna-euk'
    description = 'eDNA metabarcoding pipeline for eukaryotes (18S V9 / COI / 12S)'
```

```groovy
    run_id      = "euk-${new java.util.Date().format('yyyyMMdd-HHmmss')}"

    // Eukaryote defaults — user overrides marker-specific values at runtime
    primers_fwd = ""
    primers_rev = ""
    min_length  = 100    // 18S V9 default; COI ~313 bp; 12S ~170 bp
    max_length  = 180    // 18S V9 default
    kingdoms    = "Eukaryota"

    // Taxonomic resolution
    daa_level         = "Species"
    correlation_level = "Species"
    target_ranks      = "Phylum,Family,Genus,Species"
```

- [ ] **Step 3: Update nf-edna-euk/main.nf — pipeline name in WRITE_STATE**

In `nf-edna-euk/main.nf`, change the single line inside `WRITE_STATE.exec:` block:

```groovy
        pipeline         : "nf-edna-euk",
        marker           : params.marker ?: "18S-V9",
```

And add to `nextflow.config` params:

```groovy
    marker = "18S-V9"   // Override to "COI" or "12S" at runtime if needed
```

- [ ] **Step 4: Commit nf-edna-euk scaffold**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-euk/
git commit -m "feat: scaffold nf-edna-euk from nf-edna-16s with eukaryote defaults"
```

---

## Task 13: Create synthetic eukaryote test data and test nf-edna-euk

**Files:**
- Create: `nf-edna-euk/tests/create_test_data.py`
- Create: `nf-edna-euk/tests/train_test_model.sh`
- Create: `nf-edna-euk/tests/params_test.json`

- [ ] **Step 1: Write eukaryote FASTQ generator**

Create `nf-edna-euk/tests/create_test_data.py`:

```python
#!/usr/bin/env python3
"""
Generate synthetic 18S V9 FASTQs for pipeline testing.
Uses real 18S V9 amplicon sequences flanked by 1391F/EukBr primers.
"""
import gzip, random, pathlib

random.seed(99)

# 1391F / EukBr primers (V9)
PRIMER_F = "GTACACACCGCCCGTC"
PRIMER_R = "TGATCCTTCTGCAGGTTCACCTAC"

# Six synthetic 18S V9 core sequences from representative eukaryote groups
CORE_SEQS = [
    "CGGAGAGGGAGCCTGAGAAACGGCTACCACATCCAAGGAAGGCAGCAGGCGCGCAAATTACCCAATCCCGACACGGGGAGGT",
    "TTTAAGTTTCAGCCTTGCGACCATACTCCCCCCGGAATACCGAGGGCATCACAGACCTGTTATTGCCTCAAACTTCCATCGG",
    "GCATGGAATAATGGAATAGGACCATCGGGGCTTTCTTGGAGAGGGAGCCTGAGAAATGGCTACCACATCCAAGGAAGGCAGC",
    "AGTTTCAGCCTTTGCGACCATACTCCCCCCGGAATACCGAGGGCATCACAGACCTGTTATCGCCTCAAACTTCCATCGGTAG",
    "CGGAGAGGGAGCCTGAGAAATGGCTACCACATCCAAGGAAGGCAGCAGGCGCGCAAATTACCCAATCCCGACACGGGGAGGT",
    "GCATGGAATAATGGAATAGGACCATCGGGGCTTTCTTGGAGAGGGAGCCTGAGAAATGGCTACCACATCCAAGGAAGGCAGG",
]

TAXA = [
    "Root;Eukaryota;Opisthokonta;Metazoa;Arthropoda;Malacostraca;Decapoda",
    "Root;Eukaryota;Opisthokonta;Metazoa;Chordata;Actinopteri;Perciformes",
    "Root;Eukaryota;Viridiplantae;Streptophyta;Embryophyta;Tracheophyta;Magnoliopsida",
    "Root;Eukaryota;Opisthokonta;Fungi;Ascomycota;Saccharomycetes;Saccharomycetales",
    "Root;Eukaryota;Alveolata;Dinoflagellata;Dinophyceae;Peridiniales;Peridiniaceae",
    "Root;Eukaryota;Stramenopiles;Bacillariophyta;Bacillariophyceae;Naviculales;Naviculaceae",
]

SAMPLES = ["euk_sample1", "euk_sample2", "euk_sample3"]
READS_PER_SAMPLE = 200
OUTPUT_DIR = pathlib.Path(__file__).parent / "fixtures"
OUTPUT_DIR.mkdir(exist_ok=True)

def make_quality(length, mean_q=34):
    return "".join(chr(min(40, max(20, int(random.gauss(mean_q, 3)))) + 33) for _ in range(length))

manifest_rows = []
for sample in SAMPLES:
    out_file = OUTPUT_DIR / f"{sample}.fastq.gz"
    with gzip.open(out_file, "wt") as fh:
        for i in range(READS_PER_SAMPLE):
            core = random.choice(CORE_SEQS)
            seq  = list(PRIMER_F + core + PRIMER_R)
            for j in range(len(seq)):
                if random.random() < 0.005:
                    seq[j] = random.choice("ACGT")
            seq = "".join(seq)
            fh.write(f"@{sample}_read{i+1}\n{seq}\n+\n{make_quality(len(seq))}\n")
    manifest_rows.append(f"{sample},{out_file.resolve()}")
    print(f"Generated {out_file}")

(OUTPUT_DIR / "manifest.csv").write_text(
    "sample-id,absolute-filepath\n" + "\n".join(manifest_rows) + "\n"
)
(OUTPUT_DIR / "metadata.tsv").write_text(
    "sample-id\thabitat\tis_negative\n"
    "euk_sample1\triffle\tFALSE\n"
    "euk_sample2\tpool\tFALSE\n"
    "euk_sample3\triffle\tFALSE\n"
)

ref_path = OUTPUT_DIR / "reference_18s.fasta"
with ref_path.open("w") as fh:
    for seq, tax in zip(CORE_SEQS, TAXA):
        fh.write(f">{tax}\n{PRIMER_F}{seq}{PRIMER_R}\n")
print(f"Reference FASTA: {ref_path}")
```

- [ ] **Step 2: Write model training script**

Create `nf-edna-euk/tests/train_test_model.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pixi run --manifest-path "${SCRIPT_DIR}/../env/classification/pixi.toml" \
    Rscript "${SCRIPT_DIR}/../bin/train_idtaxa_model.R" \
    --reference_fasta "${SCRIPT_DIR}/fixtures/reference_18s.fasta" \
    --output_model "${SCRIPT_DIR}/fixtures/idtaxa_model_euk.rds" \
    --min_len 50 --max_len 300
echo "Model: ${SCRIPT_DIR}/fixtures/idtaxa_model_euk.rds"
```

- [ ] **Step 3: Write params_test.json**

Create `nf-edna-euk/tests/params_test.json`:

```json
{
  "run_id": "test-euk-run",
  "results_dir": "/tmp/nf-edna-euk-test-results",
  "input_manifest": "tests/fixtures/manifest.csv",
  "metadata": "tests/fixtures/metadata.tsv",
  "idtaxa_model": "tests/fixtures/idtaxa_model_euk.rds",
  "marker": "18S-V9",
  "primers_fwd": "GTACACACCGCCCGTC",
  "primers_rev": "TGATCCTTCTGCAGGTTCACCTAC",
  "min_length": 80,
  "max_length": 200,
  "kingdoms": "Eukaryota",
  "grouping_variable": "habitat",
  "reference_level": "riffle",
  "daa_level": "Species",
  "correlation_level": "Species",
  "decontam_threshold": 0.1,
  "neg_col": "is_negative",
  "filter_condition": "is_negative == false",
  "num_clusters": "2",
  "metadata_numeric_variables": ""
}
```

- [ ] **Step 4: Generate test data, train model, run QC, run FULL pipeline**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON/nf-edna-euk
python3 tests/create_test_data.py
bash tests/train_test_model.sh

# Test QC entry
nextflow run . -entry QC_ONLY -params-file tests/params_test.json

# Test full pipeline
nextflow run . -params-file tests/params_test.json
```

- [ ] **Step 5: Verify eukaryote outputs**

```bash
RESULTS=/tmp/nf-edna-euk-test-results/test-euk-run
python3 -c "
import json
with open('$RESULTS/pipeline_state.json') as f:
    s = json.load(f)
assert s['pipeline'] == 'nf-edna-euk'
assert s['marker'] == '18S-V9'
assert s['completed_stages'] == ['qc', 'denoise', 'classify', 'diversity', 'association']
print('pipeline_state.json: OK')
"
grep -i "Decapoda\|Actinopteri\|Fungi" \
    "$RESULTS/taxonomy/idtaxa_classification_confident.tsv" \
    && echo "Eukaryote taxa found" || echo "WARNING: no known eukaryote taxa"
```

- [ ] **Step 6: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add nf-edna-euk/
git commit -m "feat: add nf-edna-euk pipeline with synthetic test data and passing tests"
```

---

## Task 14: Write shared pipeline_state.json fixtures

These fixture files are consumed by the Claude Code skills (Plan 2). They represent realistic `pipeline_state.json` outputs at each stage for both pipelines.

**Files:**
- Create: `tests/fixtures/pipeline_state_16s_intake.json`
- Create: `tests/fixtures/pipeline_state_16s_qc.json`
- Create: `tests/fixtures/pipeline_state_16s_classify.json`
- Create: `tests/fixtures/pipeline_state_16s_full.json`
- Create: `tests/fixtures/pipeline_state_euk_intake.json`
- Create: `tests/fixtures/pipeline_state_euk_full.json`

- [ ] **Step 1: Create fixtures directory and write files**

```bash
mkdir -p /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON/tests/fixtures
```

Create `tests/fixtures/pipeline_state_16s_intake.json`:

```json
{
  "run_id": "16s-20260521-siteA",
  "pipeline": "nf-edna-16s",
  "marker": "16S",
  "completed_stages": [],
  "last_stage": "intake",
  "params_used": {
    "primers_fwd": "CCTACGGGNGGCWGCAG",
    "primers_rev": "GACTACNVGGGTWTCTAATCC",
    "min_length": 350,
    "max_length": 550,
    "kingdoms": "Bacteria,Archaea"
  },
  "outputs": {}
}
```

Create `tests/fixtures/pipeline_state_16s_qc.json`:

```json
{
  "run_id": "16s-20260521-siteA",
  "pipeline": "nf-edna-16s",
  "marker": "16S",
  "completed_stages": ["qc"],
  "last_stage": "qc",
  "params_used": {
    "primers_fwd": "CCTACGGGNGGCWGCAG",
    "primers_rev": "GACTACNVGGGTWTCTAATCC",
    "min_length": 350,
    "max_length": 550,
    "kingdoms": "Bacteria,Archaea"
  },
  "outputs": {
    "trimmed_reads": "results/16s-20260521-siteA/qc/trimmed/"
  }
}
```

Create `tests/fixtures/pipeline_state_16s_classify.json`:

```json
{
  "run_id": "16s-20260521-siteA",
  "pipeline": "nf-edna-16s",
  "marker": "16S",
  "completed_stages": ["qc", "denoise", "classify"],
  "last_stage": "classify",
  "params_used": {
    "primers_fwd": "CCTACGGGNGGCWGCAG",
    "primers_rev": "GACTACNVGGGTWTCTAATCC",
    "min_length": 350,
    "max_length": 550,
    "kingdoms": "Bacteria,Archaea"
  },
  "outputs": {
    "trimmed_reads": "results/16s-20260521-siteA/qc/trimmed/",
    "asv_table": "results/16s-20260521-siteA/asv_table/feature-table_renamed.tsv",
    "rep_seqs":  "results/16s-20260521-siteA/asv_table/rep-seqs_renamed.fna",
    "taxonomy":  "results/16s-20260521-siteA/taxonomy/idtaxa_classification_confident.tsv",
    "asv_counts": "results/16s-20260521-siteA/taxonomy/agglomerated_data/asv_counts.tsv"
  }
}
```

Create `tests/fixtures/pipeline_state_16s_full.json`:

```json
{
  "run_id": "16s-20260521-siteA",
  "pipeline": "nf-edna-16s",
  "marker": "16S",
  "completed_stages": ["qc", "denoise", "classify", "diversity", "association"],
  "last_stage": "association",
  "params_used": {
    "primers_fwd": "CCTACGGGNGGCWGCAG",
    "primers_rev": "GACTACNVGGGTWTCTAATCC",
    "min_length": 350,
    "max_length": 550,
    "kingdoms": "Bacteria,Archaea"
  },
  "outputs": {
    "trimmed_reads": "results/16s-20260521-siteA/qc/trimmed/",
    "asv_table":     "results/16s-20260521-siteA/asv_table/feature-table_renamed.tsv",
    "rep_seqs":      "results/16s-20260521-siteA/asv_table/rep-seqs_renamed.fna",
    "taxonomy":      "results/16s-20260521-siteA/taxonomy/idtaxa_classification_confident.tsv",
    "asv_counts":    "results/16s-20260521-siteA/taxonomy/agglomerated_data/asv_counts.tsv",
    "diversity":     "results/16s-20260521-siteA/diversity/",
    "association":   "results/16s-20260521-siteA/association/"
  }
}
```

Create `tests/fixtures/pipeline_state_euk_intake.json`:

```json
{
  "run_id": "euk-20260521-siteB",
  "pipeline": "nf-edna-euk",
  "marker": "18S-V9",
  "completed_stages": [],
  "last_stage": "intake",
  "params_used": {
    "primers_fwd": "GTACACACCGCCCGTC",
    "primers_rev": "TGATCCTTCTGCAGGTTCACCTAC",
    "min_length": 100,
    "max_length": 180,
    "kingdoms": "Eukaryota"
  },
  "outputs": {}
}
```

Create `tests/fixtures/pipeline_state_euk_full.json`:

```json
{
  "run_id": "euk-20260521-siteB",
  "pipeline": "nf-edna-euk",
  "marker": "18S-V9",
  "completed_stages": ["qc", "denoise", "classify", "diversity", "association"],
  "last_stage": "association",
  "params_used": {
    "primers_fwd": "GTACACACCGCCCGTC",
    "primers_rev": "TGATCCTTCTGCAGGTTCACCTAC",
    "min_length": 100,
    "max_length": 180,
    "kingdoms": "Eukaryota"
  },
  "outputs": {
    "trimmed_reads": "results/euk-20260521-siteB/qc/trimmed/",
    "asv_table":     "results/euk-20260521-siteB/asv_table/feature-table_renamed.tsv",
    "rep_seqs":      "results/euk-20260521-siteB/asv_table/rep-seqs_renamed.fna",
    "taxonomy":      "results/euk-20260521-siteB/taxonomy/idtaxa_classification_confident.tsv",
    "asv_counts":    "results/euk-20260521-siteB/taxonomy/agglomerated_data/asv_counts.tsv",
    "diversity":     "results/euk-20260521-siteB/diversity/",
    "association":   "results/euk-20260521-siteB/association/"
  }
}
```

- [ ] **Step 2: Verify all fixtures are valid JSON**

```bash
for f in /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON/tests/fixtures/*.json; do
    python3 -c "import json; json.load(open('$f'))" && echo "OK: $f" || echo "INVALID: $f"
done
```

Expected: `OK:` for all six files.

- [ ] **Step 3: Commit**

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AMPLICON
git add tests/
git commit -m "feat: add shared pipeline_state.json fixtures for skill testing"
```

---

## Self-Review Checklist

- [x] **Spec coverage:** All five subworkflows (QC, DENOISE, CLASSIFY, DIVERSITY, ASSOCIATION) implemented. `WRITE_STATE` writes `pipeline_state.json` after each named workflow. Both pipelines covered. Shared fixtures written. Entry-point mechanism implemented.
- [x] **No placeholders:** All steps contain actual code, commands, or expected output.
- [x] **Type consistency:** `DENOISE` workflow emits `.table` and `.fasta`; `CLASSIFY` takes `asv_table` and `rep_seqs` — consistent throughout. `WRITE_STATE` takes `val completed_stages` (list) and `val last_stage` (string) — consistent in all named workflows.
- [x] **One open item:** The `WRITE_STATE.exec:` block uses `task.workDir.resolve(...)` which requires the process to have a work directory. Because `exec:` processes still create a work directory, this is valid Nextflow DSL2 behaviour.
