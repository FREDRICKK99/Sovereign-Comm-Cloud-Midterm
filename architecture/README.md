# Architecture

Editable `.drawio` diagrams describe site-specific networks, federation components and multi-site expansion. Slides reflect successive research iterations, not necessarily a single as-deployed state. Validate all addresses, routes and VM mappings before deployment.

## Tested Site B components

- `b-core`: federation API, Nextflow and Slurm controller
- `b-worker`: Slurm compute node
- `b-storage`: private NFS export
- Site A: authenticated cross-site requester
- Sites C/D/E: scale-out experiment endpoints

Private Site B traffic used `10.20.20.0/24` in the documented testbed. Do not reuse public lab addresses blindly.
