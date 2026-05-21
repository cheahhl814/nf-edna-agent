# eDNA Metabarcoding Agent System — Design Spec

**Date:** 2026-05-21  
**Status:** Approved  
**Scope:** Interactive research assistant for eDNA metabarcoding analysis (eukaryotes + prokaryotes), combining Nextflow pipelines with Claude Code skills

---

## 1. Problem Statement

Researchers running eDNA metabarcoding experiments need to move from raw sequencing reads to biological interpretation. The pipeline steps are deterministic and computationally intensive; the parameter decisions and result interpretation require domain knowledge and contextual judgement. This system separates those two concerns cleanly: Nextflow handles all computation, Claude Code skills handle intelligence and interaction.

The primary use case is an **interactive research assistant** running in the Claude Code terminal. The scientist describes their experiment and inputs; the agent asks clarifying questions, configures and executes the correct pipeline, then interprets the results in plain language and answers follow-up questions.

---

## 2. Scope

**In scope:**

- Two independent Nextflow pipelines: `nf-edna-euk` (18S V9 / COI / 12S) and `nf-edna-16s` (16S prokaryotes)
- Three Claude Code skills: `edna:intake`, `edna:run`, `edna:interpret`
- Any entry point: raw FASTQs, mid-pipeline outputs, or already-processed results
- Structured Markdown report + narrative summary + interactive Q&A
- Resume behaviour across interrupted sessions

**Out of scope:**

- Web UI or non-terminal interfaces
- Simultaneous dual-pipeline runs on the same samples (each pipeline is independent)
- Biological validation of IDTAXA reference databases
- Performance benchmarking at scale

---

## 3. Overall Architecture

Three layers with no overlapping responsibilities:

```
Scientist (Claude Code terminal)
        │  invokes skills, answers questions
        ▼
┌─────────────────────────────────────────┐
│           SKILL LAYER (AI)              │
│  edna:intake → edna:run → edna:interpret│
└──────────────┬──────────────────────────┘
               │  constructs params, calls nextflow
               ▼
┌─────────────────────────────────────────┐
│        NEXTFLOW LAYER (Compute)         │
│  nf-edna-euk       nf-edna-16s          │
│  (18S/COI/12S)     (16S prokaryotes)    │
│                                         │
│  Subworkflows: QC, DENOISE, CLASSIFY,   │
│  DIVERSITY, ASSOCIATION                 │
│  Entry point: --entry [stage]           │
└──────────────┬──────────────────────────┘
               │  outputs (TSV/RDS/plots/JSON)
               ▼
┌─────────────────────────────────────────┐
│        OUTPUT LAYER (Files)             │
│  results/{run_id}/                      │
│    qc/, asv_table/, taxonomy/,          │
│    diversity/, association/,            │
│    report.md, pipeline_state.json       │
└─────────────────────────────────────────┘
```

**`pipeline_state.json`** is the contract between layers. Nextflow writes it at each completed stage. Skills read it to determine what has already run and what inputs/outputs are available. Skills never parse Nextflow log files or infer output paths.

**`run_id`** is a timestamped slug (e.g. `euk-20260521-site3`) generated at intake. All outputs, state, and reports are scoped under `results/{run_id}/`.

---

## 4. Directory Layout

```
AMPLICON/
├── nf-edna-euk/               # Eukaryote pipeline
│   ├── main.nf
│   ├── nextflow.config
│   ├── modules/
│   │   ├── qc.nf
│   │   ├── denoise.nf
│   │   ├── classify.nf
│   │   ├── diversity.nf
│   │   └── association.nf
│   ├── bin/                   # R/Python scripts called by processes
│   ├── env/                   # Pixi environment definitions
│   └── tests/
│       ├── fixtures/          # Synthetic FASTQs, minimal IDTAXA model
│       ├── params_test.json
│       └── expected_outputs/
├── nf-edna-16s/               # Prokaryote pipeline (same structure)
├── results/                   # All run outputs (gitignored)
│   └── {run_id}/
│       ├── pipeline_state.json
│       ├── report.md
│       ├── qc/
│       ├── asv_table/
│       ├── taxonomy/
│       ├── diversity/
│       └── association/
├── tests/                     # Shared tests (pipeline_state.json fixtures, skill walkthroughs)
│   ├── fixtures/              # Example pipeline_state.json for each stage + pipeline
│   └── skill-walkthroughs.md
├── docs/
│   └── superpowers/specs/
└── .claude/
    └── skills/
        ├── edna-intake.md
        ├── edna-run.md
        └── edna-interpret.md
```

---

## 5. Nextflow Pipeline Design

Both pipelines share identical subworkflow names and output contracts. Only tools, databases, and biological parameters differ. This allows the skills to use the same logic for both pipelines.

### 5.1 Shared Subworkflows

| Subworkflow   | Entry flag            | Required inputs               | Key outputs                       |
| ------------- | --------------------- | ----------------------------- | --------------------------------- |
| `QC`          | `--entry qc`          | raw FASTQs + manifest         | FastQC reports, trimmed reads     |
| `DENOISE`     | `--entry denoise`     | trimmed reads                 | ASV table (TSV), rep-seqs (FASTA) |
| `CLASSIFY`    | `--entry classify`    | ASV table + IDTAXA model      | taxonomy TSV, filtered ASV table  |
| `DIVERSITY`   | `--entry diversity`   | taxonomy TSV + metadata       | alpha/beta plots, TSE (RDS)       |
| `ASSOCIATION` | `--entry association` | TSE + metadata                | DAA results, correlation plots    |
| `FULL`        | `--entry full`        | raw FASTQs + manifest + model | all of the above                  |

### 5.2 Pipeline Differences

| Concern                   | `nf-edna-euk`                          | `nf-edna-16s`         |
| ------------------------- | -------------------------------------- | --------------------- |
| Primer trimming           | Cutadapt, marker-specific primers      | Cutadapt, 16S primers |
| Read merging              | NGmerge                                | NGmerge               |
| Length filtering          | Marker-dependent (e.g. V9: 100–180 bp) | 16S V3-V4: 350–550 bp |
| IDTAXA model              | Eukaryote reference (SILVA Euk / BOLD) | SILVA 16S             |
| Kingdom filter            | `Eukaryota`                            | `Bacteria,Archaea`    |
| Taxonomic resolution goal | Species-level                          | Genus-level           |

### 5.3 `pipeline_state.json` Schema

Written by Nextflow after each stage completes. This is the authoritative record of what has run.

```json
{
  "run_id": "euk-20260521-site3",
  "pipeline": "nf-edna-euk",
  "marker": "18S-V9",
  "completed_stages": ["qc", "denoise", "classify"],
  "last_stage": "classify",
  "params_used": {
    "min_length": 100,
    "max_length": 180,
    "kingdoms": "Eukaryota",
    "primers_fwd": "CCAGCASCYGCGGTAATTCC",
    "primers_rev": "ACTTTCGTTCTTGATYRA"
  },
  "outputs": {
    "trimmed_reads": "results/euk-20260521-site3/qc/trimmed/",
    "asv_table": "results/euk-20260521-site3/asv_table/asv_table.tsv",
    "taxonomy": "results/euk-20260521-site3/taxonomy/taxonomy.tsv"
  }
}
```

---

## 6. Skills Design

Skills are YAML-fronted Markdown files in `.claude/skills/`, auto-discovered by Claude Code.

### 6.1 `edna:intake`

**Purpose:** Determine what the scientist has and what is needed before anything runs.

**Conversation flow:**

1. Ask which marker gene / pipeline if not stated
2. If a `run_id` is provided, read existing `pipeline_state.json` and report which stages are complete
3. Validate that required files exist (manifest CSV, FASTQ paths, IDTAXA model path)
4. For any missing required parameter, ask the scientist one question at a time:
   - Forward and reverse primer sequences
   - Min/max amplicon length
   - Metadata file path and grouping variable for diversity/association
   - Minimum read count threshold
5. Confirm all collected parameters with the scientist
6. Generate `run_id`, write initial `pipeline_state.json`, write `{run_id}.json` params file
7. Inform scientist to invoke `/edna:run` when ready

**Invariant:** Never silently assumes a default. Every parameter is either provided by the scientist or explicitly asked for.

### 6.2 `edna:run`

**Purpose:** Execute the correct Nextflow pipeline stage(s) and monitor progress.

**Behaviour:**

- Reads `pipeline_state.json` to determine next stage(s) to run
- Constructs `nextflow run` command with all confirmed parameters
- Shows the full command to the scientist and waits for confirmation before executing
- Monitors stdout/stderr, surfaces errors with plain-language explanation and suggested fix
- Updates `pipeline_state.json` after each stage completes successfully
- On stage failure: extracts relevant log excerpt, explains likely cause, offers three options:
  1. Retry with adjusted parameters (asks which parameter to change)
  2. Skip this stage
  3. Abort run
- Does not update `pipeline_state.json` for failed stages, preserving resumability
- Uses Nextflow `-resume` flag transparently when continuing an existing run

### 6.3 `edna:interpret`

**Purpose:** Turn pipeline outputs into scientific understanding.

**Three modes, used in sequence:**

**Mode 1 — Structured report:** Reads all files under `results/{run_id}/`, writes `results/{run_id}/report.md` with sections:

- Run Summary (pipeline, marker, parameters used, sample count)
- QC Summary (read counts before/after trimming, pass rates)
- ASV and Taxonomy Overview (ASV count, taxonomic breakdown by rank)
- Alpha Diversity (key metrics, notable patterns)
- Beta Diversity (ordination summary, group separation)
- Differential Abundance (significant taxa, effect sizes)
- Caveats (any anomalies flagged during interpretation)

**Mode 2 — Narrative summary:** 2–3 paragraphs of plain-language findings suitable for a draft Results section, appended to `report.md` and printed to terminal.

**Mode 3 — Interactive Q&A:** Remains active after report is written. The scientist asks follow-up questions; the agent reads relevant output files to answer. Examples: "which taxa drive PC1 separation?", "is the low read count in sample 7 a problem?", "what functional roles do the dominant taxa likely have?"

**Marker-aware interpretation:**

- Eukaryote runs: lower expected ASV counts, species-level interpretation, ecological guild framing (e.g. predator/prey, trophic level)
- 16S runs: higher diversity expected, genus-level interpretation, functional guild framing (e.g. nitrifiers, sulfate reducers)

**Anomaly handling:** If an expected output is missing or empty (e.g. zero ASVs, empty taxonomy table), the agent flags this explicitly before writing the report and surfaces it as the first Caveats item. It does not silently skip sections.

### 6.4 Skill Invocation Patterns

```
# Full run from raw reads
/edna:intake

# Resume from mid-pipeline (scientist already has ASV table)
/edna:intake   # provide existing run_id when prompted

# Interpret a completed run
/edna:interpret  # provide run_id when prompted

# Run a specific stage only
/edna:run  # provide run_id + target stage when prompted
```

---

## 7. Data Flow

### Happy path

```
/edna:intake
  → elicits all parameters
  → writes pipeline_state.json (stage: "intake")
  → "Ready. Invoke /edna:run when you want to proceed."

/edna:run
  → reads pipeline_state.json
  → shows nextflow command, waits for confirmation
  → executes pipeline stage by stage
  → updates pipeline_state.json after each stage
  → "All stages complete. Invoke /edna:interpret."

/edna:interpret
  → reads results/{run_id}/
  → writes report.md
  → prints narrative summary
  → enters Q&A mode
```

### Resume path

```
Session interrupted after DENOISE completed.

/edna:intake  (provide existing run_id)
  → reads pipeline_state.json
  → "DENOISE complete. CLASSIFY, DIVERSITY, ASSOCIATION remain."

/edna:run
  → picks up from CLASSIFY using nextflow -resume
```

---

## 8. Error Handling

| Class                                                    | Where caught     | Action                                                                                 |
| -------------------------------------------------------- | ---------------- | -------------------------------------------------------------------------------------- |
| Bad inputs (missing file, bad manifest, unknown marker)  | `edna:intake`    | Report exactly what is wrong and what to fix; do not proceed                           |
| Pipeline execution failure (non-zero exit)               | `edna:run`       | Extract log excerpt, explain likely cause, offer retry/skip/abort; do not update state |
| Uninterpretable outputs (empty ASV table, missing files) | `edna:interpret` | Flag anomaly explicitly; surface as first Caveats item; do not silently skip sections  |

---

## 9. Testing

### Nextflow pipelines

Each pipeline has `tests/` with:

- Synthetic FASTQ (100–500 reads, known composition) per supported marker
- Pre-trained minimal IDTAXA model for the synthetic dataset
- `params_test.json` with test parameters
- `expected_outputs/` with reference files for pass/fail comparison

Each entry point tested individually:

```bash
nextflow run nf-edna-euk --entry qc      -params-file tests/params_test.json
nextflow run nf-edna-euk --entry denoise -params-file tests/params_test.json
nextflow run nf-edna-euk --entry classify -params-file tests/params_test.json
nextflow run nf-edna-euk --entry full    -params-file tests/params_test.json
```

Pass criterion: expected output files exist, are non-empty, known taxa appear in taxonomy output.

### `pipeline_state.json` contract

`tests/fixtures/` (at AMPLICON root) holds example state files for each stage and both pipelines. When skills are modified, manually verify correct parsing of each fixture.

### Skills

Tested via scripted walkthroughs documented in `tests/skill-walkthroughs.md` (at AMPLICON root):

1. **Intake test:** complete valid input → confirm parameters captured; incomplete input → confirm agent asks for each missing parameter one at a time
2. **Run test:** synthetic dataset → confirm correct command shown, state updated after completion
3. **Interpret test:** pre-completed results fixture → confirm all report sections generated, Q&A responds correctly to 4 standard questions

### Explicitly out of scope

- Biological correctness of IDTAXA classifications (a database quality question)
- Performance under large datasets (validated in real runs)
- Exhaustive edge cases in R scripts (inherited from `nf-emplicon`, tested there)

---

## 10. Implementation Order

1. `nf-edna-16s` pipeline (adapt from `nf-emplicon`; 16S is simpler, good baseline)
2. `nf-edna-euk` pipeline (adapt from `nf-emplicon`; add marker-gene branching)
3. `edna:intake` skill
4. `edna:run` skill
5. `edna:interpret` skill
6. Synthetic test datasets and skill walkthroughs
