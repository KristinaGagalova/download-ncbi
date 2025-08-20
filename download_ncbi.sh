#!/usr/bin/env bash
set -Eeuo pipefail

# Author: Kristina K. Gagalova
# Description: simple script to download genomes from NCBI

### Config / usage
URL='https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/v2/linux-amd64/datasets'
INPUT_TSV="${1:-assemblies.tsv}"
JOBS="${2:-4}"
INCLUDES="genome,gff3,protein,cds"   # change if you want fewer artifacts
DATASETS_BIN="./datasets"

usage() {
  cat <<EOF
Usage: $(basename "$0") <assemblies.tsv> [jobs]

- Downloads NCBI 'datasets' CLI (linux-amd64) into current dir if missing.
- Extracts accessions from the FIRST column of <assemblies.tsv>.
  * If the first line begins with "Assembly", it is treated as a header and skipped.
- Validates to keep only GCA_*/GCF_* accessions.
- Downloads (in parallel) genome+gff3+protein+cds for each accession.
- Unzips each ZIP into its own folder.

Examples:
  $(basename "$0") assemblies.tsv
  $(basename "$0") assemblies.tsv 6

Env vars you can set:
  REQUESTS_CA_BUNDLE=/path/to/ca-bundle.crt   # if your system needs a custom CA bundle
EOF
  exit 1
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

### Checks
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl not found."; exit 2; }
command -v parallel >/dev/null 2>&1 || { echo "ERROR: GNU parallel not found."; exit 2; }
command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip not found."; exit 2; }
[[ -f "$INPUT_TSV" ]] || { echo "ERROR: input TSV '$INPUT_TSV' not found."; exit 2; }

### Get datasets binary if needed
if [[ ! -x "$DATASETS_BIN" ]]; then
  echo "[*] Downloading NCBI datasets CLI -> $DATASETS_BIN"
  curl -L -o "$DATASETS_BIN" "$URL"
  chmod +x "$DATASETS_BIN"
fi

### Prepare dirs
mkdir -p zips out logs

### Build a clean accession list from column 1
# - Skip header if first field on line 1 starts with "Assembly"
# - Strip CRLF, trim spaces
# - Keep only valid GCA/GCF accessions with version suffix
ACC_LIST="assemblies.txt"
awk 'BEGIN{FS="\t"}
     NR==1 && $1 ~ /^Assembly/ { next }   # skip header
     {
       acc=$1
       sub(/\r$/,"",acc)                  # strip CR from CRLF
       gsub(/^[[:space:]]+|[[:space:]]+$/,"",acc)
       if (acc ~ /^(GCA|GCF)_[0-9]+\.[0-9]+$/) print acc
     }' "$INPUT_TSV" | sort -u > "$ACC_LIST"

if [[ ! -s "$ACC_LIST" ]]; then
  echo "ERROR: No valid accessions found in column 1 of '$INPUT_TSV'."
  echo "       Check that it is a true TSV and the first column has GCA_/GCF_ IDs."
  exit 3
fi

### Quick connectivity sanity check on the first accession
FIRST_ACC="$(head -n 1 "$ACC_LIST")"
echo "[*] Testing API reachability with: $FIRST_ACC"
if ! "$DATASETS_BIN" summary genome accession "$FIRST_ACC" >/dev/null 2>&1; then
  echo "ERROR: Unable to reach NCBI Datasets API or invalid accession: $FIRST_ACC"
  echo "       If you are on HPC and see TLS errors, set REQUESTS_CA_BUNDLE to your CA bundle."
  echo "       Example: export REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt"
  exit 4
fi

### Download each accession to its own ZIP (idempotent: skip if ZIP exists)
echo "[*] Downloading $(wc -l < "$ACC_LIST") accessions with $JOBS parallel jobs..."
parallel --bar -j "$JOBS" --joblog logs/parallel_jobs.tsv --halt now,fail=1 \
  'if [[ ! -s zips/{1}.zip ]]; then
      echo "[download] {1}"
      '"$DATASETS_BIN"' download genome accession {1} \
        --include '"$INCLUDES"' \
        --no-progressbar \
        --filename zips/{1}.zip
    else
      echo "[skip] zips/{1}.zip exists"
    fi' :::: "$ACC_LIST"

### Unzip each into its own folder (idempotent)
echo "[*] Unzipping..."
parallel --bar -j "$JOBS" 'mkdir -p out/{1} && unzip -qo zips/{1}.zip -d out/{1}' :::: "$ACC_LIST"

### Manifest (simple index of what was downloaded)
echo -e "accession\tzip_path\tout_dir" > logs/manifest.tsv
awk '{printf "%s\tzips/%s.zip\tout/%s\n",$1,$1,$1}' "$ACC_LIST" >> logs/manifest.tsv

echo "[✓] Done."
echo "    Zips:     $(pwd)/zips/"
echo "    Unzipped: $(pwd)/out/"
echo "    Manifest: $(pwd)/logs/manifest.tsv"
