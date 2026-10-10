# Reproducibility protocol

1. Establish Ubuntu 24.04 and supported Proxmox and storage versions. Record actual versions in `evidence/manifests/environment.txt` (sanitize before public upload).
2. Provision isolated per-site private networking, VMs, shared storage, FreeRADIUS/identity as appropriate, and Slurm. Use provisioning scripts only after reading and replacing environment-specific addresses, storage backends, credentials and VMIDs.
3. Deploy the Rust federation agent from the corresponding Cargo project and lockfile. The supplied Rust `main.rs.review-required` is a historical single-file candidate, **not a complete Cargo project**. Bring `Cargo.toml`, `Cargo.lock`, and non-sensitive source/config from `/home/fredrick/federation-agent` after review.
4. Configure Keycloak JWT, mTLS and OPA policies. Keep secrets outside Git.
5. Execute E1, E2/E3 and E4 experiments using locally validated scripts and archive timestamped machine-readable outputs.
6. For E5, verify b-core/b-worker/b-storage connectivity, healthy Slurm partition, Nextflow command, and NFS mount. Run the `cached` then `fresh` audit modes (only in an authorized lab and after reviewing its runtime changes). Check state restoration.
7. Analyze results with pinned software versions and publish sanitized CSV/JSON summaries; retain restricted PCAPs and real datasets off-repo.
8. Archive full commands, UTC run IDs, software versions, input fingerprints, failure/skip manifests and any deviations.

## Limitations

E2/E3 observed HTTP 403 is an expected **policy-denial response**, not a successful raw-export action. Report it as response consistency and fail-closed behavior. E5 small synthetic FASTQ is functional evidence, not production-scale genomics performance. 'No raw data egress' is not proven by header-limited PCAPs.
