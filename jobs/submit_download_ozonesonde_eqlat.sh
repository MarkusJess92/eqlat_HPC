#!/bin/bash
#SBATCH --account=co2
#SBATCH --qos=batch
#SBATCH --job-name=dl_o3sonde_eqlat
#SBATCH --partition=service
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=10G
#SBATCH --time=08:00:00
#SBATCH --output=/work2/noaa/co2/jesswein/logs/%x_%j.out
#SBATCH --error=/work2/noaa/co2/jesswein/logs/%x_%j.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=markus.jesswein@noaa.gov
###############################################################################
#  SLURM job: Boulder ozonesonde download + matching ERA5/MERRA-2
#
#  Three steps:
#    1. Download Boulder native-resolution ozonesonde profiles, one call per
#       year (download_ozonesondes.py's original single-year CLI — no GPS
#       lat/lon filtering, all profiles are kept; that filter was reverted
#       on 2026-07-20, see project memory / chat history if you want it
#       back).
#    2. Build a plain date list (one YYYY-MM-DD per line) from the
#       filenames of the ozonesonde CSVs just downloaded
#       (ozonesonde_<flight_nr>_<location>_<YYYYMMDD>.csv), deduplicated.
#       This does NOT require touching download_ozonesondes.py.
#    3. Download ERA5 PV/T (pressure levels) for exactly those dates.
#    4. Download MERRA-2 EPV/T (pressure levels) for exactly those dates.
#
#  ERA5/MERRA-2 output goes to $DATA/ERA5_ozonesonde and
#  $DATA/MERRA2_ozonesonde (separate from the full-year climatology
#  downloads in ERA5_12UTC / MERRA2, so this does not interfere with
#  submit_download_ERA5.sh / submit_download_MERRA2.sh or get
#  auto-picked-up by submit_process_eqlat.sh).
#
#  All download steps skip files that already exist, so if the job runs
#  out of walltime it is safe to simply re-submit — it will resume where
#  it left off.
#
#  Usage:
#      sbatch submit_download_ozonesonde_eqlat.sh
#      sbatch submit_download_ozonesonde_eqlat.sh 2005 2025
#      sbatch submit_download_ozonesonde_eqlat.sh 2005 2025 "https://gml.noaa.gov/aftp/data/ozwv/Ozonesonde/Boulder,%20Colorado/Native%20Resolution%20(60s,%207s,%201s)/"
#      sbatch submit_download_ozonesonde_eqlat.sh 2005 2025 "" 2020 2025   # ERA5/MERRA-2 nur 2020-2025
#
#  Arguments:
#      $1  Start year              (optional, default: 2005)
#      $2  End year                (optional, default: 2025)
#      $3  Ozonesonde base URL     (optional, default: NOAA GML Boulder, CO)
#      $4  ERA5/MERRA-2 start year (optional, default: same as $1)
#      $5  ERA5/MERRA-2 end year   (optional, default: same as $2)
#
#  NOTE ON PARTITION: this job uses --partition=service (not orion).
#  Regular `orion` compute nodes have no outbound internet access — only
#  the `service` partition runs on front-end/login nodes with external
#  network connectivity, needed here for gml.noaa.gov / CDS / NASA GES
#  DISC requests. `service` is capped at 1 core / 24h, matching this
#  job's resource request.
###############################################################################

set -eo pipefail

# ---------- Argument handling ----------
YEAR_START=${1:-2005}
YEAR_END=${2:-2025}
O3_URL=${3:-"https://gml.noaa.gov/aftp/data/ozwv/Ozonesonde/Boulder,%20Colorado/Native%20Resolution%20(60s,%207s,%201s)/"}
ERA5_MERRA2_START=${4:-$YEAR_START}
ERA5_MERRA2_END=${5:-$YEAR_END}

DATA_ROOT=${DATA:-/work2/noaa/co2/jesswein/data}
O3_OUTDIR="${DATA_ROOT}/ozonesonde"
DATES_FILE="${O3_OUTDIR}/o3sonde_dates.txt"
DATES_FILE_FILTERED="${O3_OUTDIR}/o3sonde_dates_era5_merra2.txt"
ERA5_OUTDIR="${DATA_ROOT}/ERA5_ozonesonde"
MERRA2_OUTDIR="${DATA_ROOT}/MERRA2_ozonesonde"

echo "============================================"
echo "  Ozonesonde + ERA5/MERRA-2 Download Job"
echo "  Years        : $YEAR_START - $YEAR_END"
echo "  Sonde URL    : $O3_URL"
echo "  Sonde outdir : $O3_OUTDIR"
echo "  Dates file   : $DATES_FILE"
echo "  ERA5/MERRA-2 : $ERA5_MERRA2_START - $ERA5_MERRA2_END"
echo "  ERA5 outdir  : $ERA5_OUTDIR"
echo "  MERRA2 outdir: $MERRA2_OUTDIR"
echo "  Job ID       : $SLURM_JOB_ID"
echo "  Node         : $HOSTNAME"
echo "  Started      : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

module purge
source /work2/noaa/co2/miniconda3/etc/profile.d/conda.sh

# ---------- Step 1: Ozonesonde download (per year) ----------
# Needs requests, beautifulsoup4, pandas, numpy.
#conda activate ccgg

#for YEAR in $(seq "$YEAR_START" "$YEAR_END"); do
#    echo ""
#    echo "### Step 1: Ozonesonde download for $YEAR ###"
#    python "${HOME}/eqlat_HPC/src/download/download_ozonesondes.py" \
#        "$YEAR" \
#        --url    "$O3_URL" \
#        --outdir "$O3_OUTDIR"
#done

#conda deactivate

# ---------- Step 2: Build date list from downloaded CSV filenames ----------
#echo ""
#echo "### Step 2: Building date list from ozonesonde CSVs ###"
#ls "${O3_OUTDIR}"/ozonesonde_*.csv 2>/dev/null \
#    | sed -E 's/.*_([0-9]{8})\.csv$/\1/' \
#    | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})$/\1-\2-\3/' \
#    | sort -u > "$DATES_FILE"

#N_DATES=$(wc -l < "$DATES_FILE")
#echo "Found $N_DATES distinct ozonesonde flight dates."

#if [ "$N_DATES" -le 0 ]; then
#    echo "No ozonesonde profiles found — skipping ERA5/MERRA-2 download."
#    exit 0
#fi

# ---------- Step 3 pre: Filter dates to ERA5/MERRA-2 time range ----------
echo ""
echo "### Filtering dates to ${ERA5_MERRA2_START}-${ERA5_MERRA2_END} ###"
awk -F'-' '$1 >= '"$ERA5_MERRA2_START"' && $1 <= '"$ERA5_MERRA2_END"'' "$DATES_FILE" \
    > "$DATES_FILE_FILTERED"
N_FILTERED=$(wc -l < "$DATES_FILE_FILTERED")
echo "Dates in range: $N_FILTERED"

if [ "$N_FILTERED" -le 0 ]; then
    echo "Keine Daten im gewählten Zeitraum — ERA5/MERRA-2 Download wird übersprungen."
    exit 0
fi

# ---------- Step 3: ERA5 for those dates ----------
conda activate e5

echo ""
echo "### Step 3: ERA5 download for ozonesonde dates ###"
python "${HOME}/eqlat_HPC/src/download/download_ERA_5.py" \
    --dates-file "$DATES_FILE_FILTERED" \
    --outdir     "$ERA5_OUTDIR"

conda deactivate

# ---------- Step 4: MERRA-2 for those dates ----------
conda activate ccgg

echo ""
echo "### Step 4: MERRA-2 download for ozonesonde dates ###"
python "${HOME}/eqlat_HPC/src/download/download_MERRA_2_new.py" \
    --dates-file "$DATES_FILE_FILTERED" \
    --outdir     "$MERRA2_OUTDIR"

conda deactivate

echo ""
echo "============================================"
echo "  Finished : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
