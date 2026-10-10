# Results and provenance

`scale/` contains available aggregate CSV artifacts. The authoritative E1–E5 raw result files remain on the experiment controller at `/root/genomics-final-experiment/` and **must be collected, reviewed and sanitized before publication**. Collection and sanitation tooling is under `tools/`. Do not treat numerical examples in README as substitutes for the source CSVs.

- E1: network impairment validation
- E2/E3: randomized 3-, 4- and 5-site DDIL requests; trace-level timing
- E4: JWT/mTLS/OPA failure-closed tests
- E5: cached and fresh Nextflow/Slurm execution, six-interface egress captures, metadata-only traffic summaries

Raw PCAPs, personal/genomic datasets, and secrets should be retained in restricted storage, not a public Git repository.
