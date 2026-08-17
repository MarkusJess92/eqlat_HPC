"""
Interpolate ERA5/MERRA-2 equivalent-latitude fields onto ozonesonde profiles.

Given per-day equivalent-latitude NetCDF files produced by process_fields.py
(dims: time, theta, lat, lon — one file per model x method x day, e.g.
'era5_eqlat_roi_20230201.nc'), this script matches each ozonesonde profile
CSV (from download_ozonesondes.py) to the file(s) for its flight date and
interpolates equivalent latitude onto every scan of the profile:

    - vertical:  potential temperature is computed from the sonde's own
      pressure + temperature (theta = T * (p0/p)^kappa) and interpolated
      along the reanalysis field's theta axis
    - horizontal: the sonde's position (per-scan GPS lat/lon if the profile
      has it, otherwise the fixed launch-site lat/lon) is interpolated
      along the reanalysis field's lat/lon axes
    - temporal:  each scan's own timestamp ('DATETIME GMT' column) is
      interpolated along the reanalysis field's time axis

All four dimensions are interpolated simultaneously (linear) using
xarray's vectorized pointwise interpolation, so this is one interp() call
per profile per available eqlat source rather than one call per scan.

Output: one CSV per profile (same filename as the input), written to
--outdir, with the original sonde columns plus up to four new columns:
    eqlat_ERA5_roi, eqlat_ERA5_piecewise,
    eqlat_MERRA2_roi, eqlat_MERRA2_piecewise
(only the ones for which a matching NetCDF file was found).

Column auto-detection
----------------------
The exact column names in the sonde CSVs can vary (they come straight from
NOAA GML's native-resolution header, flattened as "Name Unit"). Pressure
and temperature columns are auto-detected via case-insensitive substring
matching ('press', 'temp'); GPS position columns via ('gps' + 'lat'/'lon').
Every detection is printed so you can sanity-check it in the SLURM log —
if it picks the wrong column, override with --press-col/--temp-col/
--lat-col/--lon-col.

Assumptions (override if wrong for your files):
    - Pressure is in hPa.
    - Temperature is in degrees Celsius (--temp-units K to disable the
      +273.15 conversion).
"""

from __future__ import annotations

import glob
import os
import re
import sys

import numpy as np
import pandas as pd

try:
    import xarray as xr
    _HAS_XR = True
except ImportError:
    _HAS_XR = False

# Add src/ to sys.path so the 'eqlat' package (at eqlat_HPC/src/eqlat/) can be imported
sys.path.insert(0, os.path.join(os.environ.get("HOME", ""), "eqlat_HPC", "src"))
from eqlat.interpolation import potential_temperature


_TIME_NAMES = ("time", "valid_time")
_LAT_NAMES  = ("latitude", "lat", "nlat", "y")
_LON_NAMES  = ("longitude", "lon", "nlon", "x")

_SOURCES = [
    # (output column suffix, filename prefix, method)
    ("ERA5_roi",         "era5",   "roi"),
    ("ERA5_piecewise",   "era5",   "piecewise"),
    ("MERRA2_roi",        "merra2", "roi"),
    ("MERRA2_piecewise",  "merra2", "piecewise"),
]


# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------

def _find_dim(ds, candidates):
    for name in candidates:
        if name in ds.dims:
            return name
    raise KeyError(f"Could not find any of {candidates} among dims {list(ds.dims)}")


def _find_col(df, substrings, label, override=None):
    """Return the first column whose lowercased name contains any of `substrings`."""
    if override:
        if override not in df.columns:
            raise KeyError(
                f"--{label}-col override '{override}' not found in columns {list(df.columns)}"
            )
        return override

    for pattern in substrings:
        for c in df.columns:
            if pattern in c.lower():
                return c

    raise KeyError(
        f"Could not auto-detect the '{label}' column. Tried substrings {substrings} "
        f"against columns {list(df.columns)}. Set explicitly via --{label}-col."
    )


def _find_gps_col(df, coord, override=None):
    """Return a per-scan GPS lat/lon column if present, else None. coord = 'lat' or 'lon'."""
    if override:
        return override if override in df.columns else None
    for c in df.columns:
        lc = c.lower()
        if "gps" in lc and coord in lc:
            return c
    return None


def _normalize_lon_to_grid(query_lon, grid_lon):
    """Wrap query longitudes into whichever convention the grid uses (-180..180 or 0..360)."""
    grid_lon = np.asarray(grid_lon, dtype=np.float64)
    query_lon = np.asarray(query_lon, dtype=np.float64)
    if grid_lon.max() > 180.0 + 1e-6:
        return query_lon % 360.0
    return ((query_lon + 180.0) % 360.0) - 180.0


def _interp_profile_to_eqlat(eqlat_da, times, thetas, lats, lons,
                              time_dim, theta_dim, lat_dim, lon_dim):
    """
    Vectorized pointwise (linear) interpolation of a 4-D eqlat DataArray
    to N profile points, one interp() call for the whole profile.
    """
    query = {
        time_dim:  xr.DataArray(times,  dims="obs"),
        theta_dim: xr.DataArray(thetas, dims="obs"),
        lat_dim:   xr.DataArray(lats,   dims="obs"),
        lon_dim:   xr.DataArray(lons,   dims="obs"),
    }
    return eqlat_da.interp(query, method="linear").values


def _extract_date_str(filename):
    """Extract the trailing YYYYMMDD from an ozonesonde CSV filename."""
    m = re.search(r"_(\d{8})\.csv$", filename)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
#  Per-profile processing
# ---------------------------------------------------------------------------

def process_one_profile(csv_path, out_path, date_str,
                         era5_eqlat_dir, merra2_eqlat_dir,
                         press_col=None, temp_col=None,
                         lat_col=None, lon_col=None,
                         temp_units="C", verbose=True):
    """
    Match one ozonesonde profile CSV to available ERA5/MERRA-2 eqlat fields
    and write an augmented CSV with eqlat_<source> columns.

    Returns
    -------
    int : number of eqlat columns added (0 if none of the sources matched).
    """
    df = pd.read_csv(csv_path)

    press = _find_col(df, ("press", "pres"), "press", override=press_col)
    temp  = _find_col(df, ("temp",),         "temp",  override=temp_col)

    gps_lat = _find_gps_col(df, "lat", override=lat_col)
    gps_lon = _find_gps_col(df, "lon", override=lon_col)

    if gps_lat and gps_lon:
        lats = df[gps_lat].astype(float).to_numpy()
        lons = df[gps_lon].astype(float).to_numpy()
        position_source = f"GPS per-scan ({gps_lat}, {gps_lon})"
    else:
        lats = np.full(len(df), float(df["launch_lat"].iloc[0]))
        lons = np.full(len(df), float(df["launch_lon"].iloc[0]))
        position_source = "fixed launch site (launch_lat/launch_lon)"

    if verbose:
        print(f"    columns: press='{press}' temp='{temp}' position={position_source}")

    T_K = df[temp].astype(float).to_numpy()
    if temp_units == "C":
        T_K = T_K + 273.15
    P_hPa = df[press].astype(float).to_numpy()
    theta_K = potential_temperature(T_K, P_hPa)

    scan_times = pd.to_datetime(df["DATETIME GMT"]).to_numpy()

    n_added = 0
    for suffix, prefix, method in _SOURCES:
        eqlat_dir = era5_eqlat_dir if prefix == "era5" else merra2_eqlat_dir
        if not eqlat_dir:
            continue

        nc_path = os.path.join(eqlat_dir, f"{prefix}_eqlat_{method}_{date_str}.nc")
        if not os.path.exists(nc_path):
            continue

        try:
            ds = xr.open_dataset(nc_path)
            t_dim = _find_dim(ds, _TIME_NAMES)
            y_dim = _find_dim(ds, _LAT_NAMES)
            x_dim = _find_dim(ds, _LON_NAMES)
            theta_dim = "theta"  # always this name in process_fields.py output

            lons_q = _normalize_lon_to_grid(lons, ds[x_dim].values)

            eqlat_vals = _interp_profile_to_eqlat(
                ds["eqlat"], scan_times, theta_K, lats, lons_q,
                t_dim, theta_dim, y_dim, x_dim,
            )
            df[f"eqlat_{suffix}"] = eqlat_vals
            n_added += 1
            ds.close()
        except Exception as e:
            print(f"    WARNING: {suffix} match failed for {date_str}: {e}")

    if n_added > 0:
        df["theta_K"] = theta_K
        df.to_csv(out_path, index=False)

    return n_added


# ---------------------------------------------------------------------------
#  CLI entry point
# ---------------------------------------------------------------------------

def main():
    import argparse

    if not _HAS_XR:
        raise ImportError("xarray is required: pip install xarray")

    parser = argparse.ArgumentParser(
        description="Interpolate ERA5/MERRA-2 equivalent-latitude fields onto ozonesonde profiles."
    )
    parser.add_argument("--sonde-indir", required=True,
                         help="Directory with ozonesonde_*.csv profiles")
    parser.add_argument("--era5-eqlat-dir", default=None,
                         help="Directory with era5_eqlat_{roi,piecewise}_YYYYMMDD.nc files")
    parser.add_argument("--merra2-eqlat-dir", default=None,
                         help="Directory with merra2_eqlat_{roi,piecewise}_YYYYMMDD.nc files")
    parser.add_argument("--outdir", required=True,
                         help="Directory to write augmented profile CSVs")
    parser.add_argument("--press-col", default=None, help="Override pressure column name")
    parser.add_argument("--temp-col", default=None, help="Override temperature column name")
    parser.add_argument("--lat-col", default=None, help="Override GPS latitude column name")
    parser.add_argument("--lon-col", default=None, help="Override GPS longitude column name")
    parser.add_argument("--temp-units", choices=["C", "K"], default="C",
                         help="Units of the temperature column (default: C)")
    args = parser.parse_args()

    if not args.era5_eqlat_dir and not args.merra2_eqlat_dir:
        parser.error("At least one of --era5-eqlat-dir / --merra2-eqlat-dir must be given.")

    os.makedirs(args.outdir, exist_ok=True)

    sonde_files = sorted(glob.glob(os.path.join(args.sonde_indir, "ozonesonde_*.csv")))
    print(f"=== Matching {len(sonde_files)} ozonesonde profiles in {args.sonde_indir} ===")
    print(f"    ERA5 eqlat dir  : {args.era5_eqlat_dir}")
    print(f"    MERRA2 eqlat dir: {args.merra2_eqlat_dir}")
    print(f"    Outdir          : {args.outdir}")

    n_matched, n_skipped, n_failed = 0, 0, 0

    for path in sonde_files:
        fname = os.path.basename(path)
        date_str = _extract_date_str(fname)
        if date_str is None:
            print(f"  Skipping {fname}: could not parse date from filename.")
            n_skipped += 1
            continue

        out_path = os.path.join(args.outdir, fname)
        if os.path.exists(out_path):
            n_skipped += 1
            continue

        candidates = []
        if args.era5_eqlat_dir:
            candidates += [
                os.path.join(args.era5_eqlat_dir, f"era5_eqlat_roi_{date_str}.nc"),
                os.path.join(args.era5_eqlat_dir, f"era5_eqlat_piecewise_{date_str}.nc"),
            ]
        if args.merra2_eqlat_dir:
            candidates += [
                os.path.join(args.merra2_eqlat_dir, f"merra2_eqlat_roi_{date_str}.nc"),
                os.path.join(args.merra2_eqlat_dir, f"merra2_eqlat_piecewise_{date_str}.nc"),
            ]
        if not any(os.path.exists(c) for c in candidates):
            n_skipped += 1
            continue

        print(f"  {fname}  ({date_str})")
        try:
            n_added = process_one_profile(
                path, out_path, date_str,
                era5_eqlat_dir=args.era5_eqlat_dir,
                merra2_eqlat_dir=args.merra2_eqlat_dir,
                press_col=args.press_col, temp_col=args.temp_col,
                lat_col=args.lat_col, lon_col=args.lon_col,
                temp_units=args.temp_units,
            )
            if n_added > 0:
                print(f"    -> added {n_added} eqlat column(s), wrote {out_path}")
                n_matched += 1
            else:
                print(f"    -> no eqlat source could be matched, skipping output.")
                n_skipped += 1
        except Exception as e:
            print(f"  ERROR {fname}: {e}")
            n_failed += 1

    print("")
    print(f"=== Done: {n_matched} matched, {n_skipped} skipped, {n_failed} failed "
          f"(of {len(sonde_files)} profiles) ===")


if __name__ == "__main__":
    main()
