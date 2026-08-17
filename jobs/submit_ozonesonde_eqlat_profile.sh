#!/bin/bash
#SBATCH --account=co2
#SBATCH --qos=batch
#SBATCH --job-name=o3sonde_eqlat_profile
#SBATCH --partition=orion
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=10G
#SBATCH --time=08:00:00
#SBATCH --output=/work2/noaa/co2/jesswein/logs/%x_%j.out
#SBATCH --error=/work2/noaa/co2/jesswein/logs/%x_%j.err
#SBATCH --mail-type=END,FAIL
#SBATCH --mail-user=markus.jesswein@noaa.gov
###############################################################################
#  SLURM job: Equivalent latitude along ozonesonde profiles
#
#  For every ozonesonde profile that has a matching ERA5 and/or MERRA-2
#  reanalysis file (downloaded by submit_download_ozonesonde_eqlat.sh into
#  $DATA/ERA5_ozonesonde / $DATA/MERRA2_ozonesonde), this computes the
#  equivalent-latitude field for that day and interpolates it onto every
#  scan of the profile (vertically via the sonde's own potential
#  temperature, horizontally via its GPS or launch-site position,
#  temporally via its scan timestamp).
#
#  Three steps (all skip already-computed/matched files, safe to re-submit):
#    1. eqlat field for ERA5_ozonesonde  -> $RESULTS/eqlat_ERA5_ozonesonde
#       (src/calc/process_fields.py --model ERA5, both piecewise + roi)
#    2. eqlat field for MERRA2_ozonesonde -> $RESULTS/eqlat_MERRA2_ozonesonde
#       (src/calc/process_fields.py --model MERRA2, both piecewise + roi)
#    3. match each ozonesonde profile in $DATA/ozonesonde against the
#       fields from steps 1/2 -> $RESULTS/ozonesonde_eqlat
#       (src/calc/match_ozonesonde_eqlat.py)
#
#  Step 3 auto-detects the sonde CSV's pressure/temperature/GPS columns by
#  substring match and prints what it picked for every profile — check the
#  .out log the first time you run this and use --press-col/--temp-col/
#  --lat-col/--lon-col overrides in match_ozonesonde_eqlat.py if it guesses
#  wrong for your files.
#
#  Usage:
#      sbatch submit_ozonesonde_eqlat_profile.sh
#      sbatch submit_ozonesonde_eqlat_profile.sh /custom/data/root /custom/results/root
#
#  Arguments:
#      $1  DATA root    (optional, default: $DATA or /work2/noaa/co2/jesswein/data)
#      $2  RESULTS root (optional, default: $RESULTS or /work2/noaa/co2/jesswein/results)
###############################################################################

set -eo pipefail

# ---------- Argument handling ----------
DATA_ROOT=${1:-${DATA:-/work2/noaa/co2/jesswein/data}}
RESULTS_ROOT=${2:-${RESULTS:-/work2/noaa/co2/jesswein/results}}

ERA5_INDIR="${DATA_ROOT}/ERA5_ozonesonde"
MERRA2_INDIR="${DATA_ROOT}/MERRA2_ozonesonde"
SONDE_INDIR="${DATA_ROOT}/ozonesonde"

ERA5_EQLAT_OUTDIR="${RESULTS_ROOT}/eqlat_ERA5_ozonesonde"
MERRA2_EQLAT_OUTDIR="${RESULTS_ROOT}/eqlat_MERRA2_ozonesonde"
MATCH_OUTDIR="${RESULTS_ROOT}/ozonesonde_eqlat"

echo "============================================"
echo "  Ozonesonde Equivalent-Latitude-Along-Profile Job"
echo "  ERA5 indir       : $ERA5_INDIR"
echo "  MERRA2 indir      : $MERRA2_INDIR"
echo "  Sonde indir       : $SONDE_INDIR"
echo "  ERA5 eqlat outdir : $ERA5_EQLAT_OUTDIR"
echo "  MERRA2 eqlat outdir: $MERRA2_EQLAT_OUTDIR"
echo "  Match outdir      : $MATCH_OUTDIR"
echo "  Job ID            : $SLURM_JOB_ID"
echo "  Node              : $HOSTNAME"
echo "  CPUs              : $SLURM_CPUS_PER_TASK"
echo "  Started           : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# ---------- Environment ----------
source /work2/noaa/co2/miniconda3/etc/profile.d/conda.sh
conda activate /work2/noaa/co2/jesswein/conda_envs/ccgg_clone

set -u
export OMP_NUM_THREADS=$SLURM_CPUS_PER_TASK

# ---------- Step 1: ERA5 eqlat fields ----------
echo ""
echo "### Step 1/3: ERA5 eqlat fields ###"
python "${HOME}/eqlat_HPC/src/calc/process_fields.py" \
    --indir  "$ERA5_INDIR" \
    --outdir "$ERA5_EQLAT_OUTDIR" \
    --model  ERA5 #\
    #--roi

# ---------- Step 2: MERRA-2 eqlat fields ----------
echo ""
echo "### Step 2/3: MERRA-2 eqlat fields ###"
python "${HOME}/eqlat_HPC/src/calc/process_fields.py" \
    --indir  "$MERRA2_INDIR" \
    --outdir "$MERRA2_EQLAT_OUTDIR" \
    --model  MERRA2 #\
    #--roi

# ---------- Step 3: Match ozonesonde profiles to eqlat fields ----------
echo ""
echo "### Step 3/3: Match ozonesonde profiles ###"
python "${HOME}/eqlat_HPC/src/calc/match_ozonesonde_eqlat.py" \
    --sonde-indir       "$SONDE_INDIR" \
    --era5-eqlat-dir    "$ERA5_EQLAT_OUTDIR" \
    --merra2-eqlat-dir  "$MERRA2_EQLAT_OUTDIR" \
    --outdir            "$MATCH_OUTDIR"

echo ""
echo "============================================"
echo "  Finished : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
