#!/usr/bin/env bash
set -Eeuo pipefail
repo="${1:-.}"
cd "$repo"
echo 'Checking for forbidden file types...'
find . -path './.git' -prune -o -type f \( -iname '*.pcap' -o -iname '*.pcapng' -o -iname '*.key' -o -iname '*.pem' -o -iname '*.fastq*' -o -iname '*.bam' -o -iname '*.vcf*' -o -iname 'site.env' \) -print
printf '\nPotential embedded credentials (manually examine matches):\n'
grep -RInE --exclude-dir=.git --exclude='prepublish-check.sh' '(BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|password[[:space:]]*[:=]|client_secret[[:space:]]*[:=]|Authorization:[[:space:]]*Bearer|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy][[:space:]]*[:=])' . || true
printf '\nInspect tracked paths with: git status --short; git diff --cached --stat\n'
