# eqlat_HPC — Equivalent Latitude Computation for NOAA HPC Orion

[![DOI](https://zenodo.org/badge/1237033987.svg)](https://doi.org/10.5281/zenodo.20706430)

A Python package for computing **equivalent latitude** (φ_e) from potential vorticity (PV) fields on isentropic surfaces. Supports ERA5 and MERRA-2 reanalysis data.

## Background

Equivalent latitude maps PV isolines to latitudes of equal enclosed area, providing a dynamically consistent coordinate for stratospheric tracer analysis. For a PV threshold q₀:

```
A(q₀) = area where PV > q₀
φ_e   = arcsin(1 − A / (2π R²))
```

## Methods

| Method | Module | Description |
|---|---|---|
| **Piecewise** | `eqlat.piecewise` | Traditional piecewise-constant method |
| **ROI** | `eqlat.roi_fast` | Region of Interest method (Añel et al., 2013) |
| **SWOOSH** | `eqlat.swoosh` | Ozone-based equivalent latitude for ozonesonde profiles |

The ROI method uses contour integration for more accurate area estimation, especially for complex PV distributions with holes or dateline crossings.


### Installation

```bash
conda env create -f environment.yml
conda activate eqlat
```

### Dependencies

```
numpy
xarray
scipy
contourpy
pandas
netcdf4
xesmf           # regridding (ERA5 → MERRA-2 grid)
tqdm            # optional, for progress bars
cdsapi          # optional, for ERA5 downloads
earthaccess     # optional, for MERRA-2 downloads
requests        # optional, for ozonesonde / MERRA-2 HTTP downloads
beautifulsoup4  # optional, for ozonesonde file-list parsing
```

## Quick Start

### Single PV field

```python
import numpy as np
from eqlat import equivalent_latitude_piecewise, equivalent_latitude_roi

# pv: 2D array (nlat, nlon) on one isentropic surface [PVU]
result = equivalent_latitude_roi(pv, lat, lon, n_thresholds=200)

print(result["pv_thresholds"])  # PV values
print(result["eqlat"])          # equivalent latitudes [°N]
```

### Full equivalent latitude map

```python
from eqlat.roi_fast import eqlat_field_roi
from eqlat.piecewise import eqlat_field_piecewise

eqlat_map = eqlat_field_roi(pv, lat, lon)   # shape (nlat, nlon)
```


### Batch processing — PV on pressure levels (ERA5 / MERRA-2)

```python
from eqlat.batch import process_pressure_netcdf

theta_levels = [320, 340, 350, 360, 380, 400, 500, 600, 700, 800]

ds = process_pressure_netcdf(
    "MERRA2_400.inst3_3d_asm_Np.20050101.nc4",
    theta_levels=theta_levels,
    method="roi",
    n_workers=4,        # parallel processing
)
ds["eqlat"].sel(theta=380).isel(time=0).plot()
```

### Ozonesonde equivalent latitude via SWOOSH

```python
from eqlat.swoosh import equivalent_latitude_swoosh_new
import xarray as xr
import numpy as np

swoosh_ds = xr.open_dataset("path_to_SWOOSH_product")

eqlat, o3_ref = equivalent_latitude_swoosh_new(
    swoosh_ds,
    sonde_theta=theta_array,       # potential temperature [K]
    sonde_o3=o3_array,             # ozone mixing ratio [ppmv]
    sonde_time=np.datetime64("2005-01-15"),
)
```

## Source Modules

| Module | Description |
|---|---|
| `src/download/download_ERA_5.py` | Download ERA5 PV + temperature from CDS |
| `src/download/download_MERRA_2_new.py` | Download MERRA-2 EPV + temperature via earthaccess |
| `src/download/download_mls.py` | Download MLS (Microwave Limb Sounder) ozone profiles |
| `src/download/download_ozonesondes.py` | Download ozonesonde data (one call per year, all profiles) |
| `src/calc/merge_reanalysis.py` | Merge reanalysis files |
| `src/calc/process_fields.py` | Batch compute equivalent latitude fields |
| `src/calc/match_ozonesonde_eqlat.py` | Interpolate ERA5/MERRA-2 equivalent-latitude fields onto ozonesonde profiles (per-scan, using the sonde's own pressure/temperature/position/time) |
| `src/analysis/reanalysis_stats.py` | Seasonal bias & RMSD between ERA5 and MERRA-2 eqlat |

### Batch processing from the command line

```bash
python src/calc/process_fields.py \
    --indir  /data/era5/pv \
    --outdir /data/era5/eqlat \
    --model  ERA5 \
    --roi
```

## SLURM Jobs (Orion)

Submit scripts in `jobs/` are configured for the `co2` account on the `orion` partition.

| Script | Description |
|---|---|
| `jobs/submit_download_ERA5.sh` | Download ERA5 for a given year: `sbatch submit_download_ERA5.sh 2023` |
| `jobs/submit_download_MERRA2.sh` | Download MERRA-2 for a given year: `sbatch submit_download_MERRA2.sh 2023` |
| `jobs/submit_download_ozonesonde_eqlat.sh` | Download Boulder ozonesondes, then ERA5 + MERRA-2 for exactly those flight dates: `sbatch submit_download_ozonesonde_eqlat.sh 2005 2025` |
| `jobs/submit_process_eqlat.sh` | Compute eqlat fields (both piecewise + ROI, skips existing files) |
| `jobs/submit_ozonesonde_eqlat_profile.sh` | Compute ERA5/MERRA-2 eqlat fields for the ozonesonde days, then interpolate onto each profile: `sbatch submit_ozonesonde_eqlat_profile.sh` |
| `jobs/submit_reanalysis_stats.sh` | Compute seasonal bias & RMSD between ERA5 and MERRA-2 |

## Notebooks

| Notebook | Description |
|---|---|
| `notebooks/00_anel_figures.ipynb` | Reproduce figures from Añel et al. (2013) |
| `notebooks/01_analytic_eqlat_comparison.ipynb` | Validate methods against analytic solutions |
| `notebooks/02_reanalysis_comparison.ipynb` | ERA5 vs. MERRA-2 eqlat comparison |
| `notebooks/03_ozone_satellite_comparison.ipynb` | Eqlat comparison with ozone satellite data |

## Package Structure

```
eqlat_HPC/
├── src/
│   ├── eqlat/
│   │   ├── piecewise.py      # piecewise-constant method
│   │   ├── roi_fast.py       # ROI method (contourpy-based)
│   │   ├── swoosh.py         # SWOOSH ozone method
│   │   ├── interpolation.py  # pressure → isentropic interpolation
│   │   ├── batch.py          # NetCDF batch processing
│   │   └── utils.py          # grid-cell areas, coordinate helpers
│   ├── download/
│   │   ├── download_ERA_5.py
│   │   ├── download_MERRA_2_new.py
│   │   ├── download_mls.py
│   │   └── download_ozonesondes.py
│   ├── analysis/
│   │   └── reanalysis_stats.py
│   └── calc/
│       ├── merge_reanalysis.py
│       ├── process_fields.py
│       └── match_ozonesonde_eqlat.py
├── jobs/
│   ├── submit_download_ERA5.sh
│   ├── submit_download_MERRA2.sh
│   ├── submit_download_ozonesonde_eqlat.sh
│   ├── submit_process_eqlat.sh
│   ├── submit_ozonesonde_eqlat_profile.sh
│   └── submit_reanalysis_stats.sh
├── notebooks/
│   ├── 00_anel_figures.ipynb
│   ├── 01_analytic_eqlat_comparison.ipynb
│   ├── 02_reanalysis_comparison.ipynb
│   └── 03_ozone_satellite_comparison.ipynb
├── README.md
└── LICENSE
```

## Data Release

Pre-computed equivalent latitude fields for ERA5 and MERRA-2 may are archived on Zenodo (not sure if that will actually happen):

[![DOI](https://zenodo.org/badge/1237033987.svg)](https://doi.org/10.5281/zenodo.20706430)

### Contents

| Dataset | Period | Levels | Method | Format |
|---|---|---|---|---|
| ERA5 eqlat | 2023–2025 | 320–800 K (10 isentropes) | ROI + piecewise | NetCDF-4 |
| MERRA-2 eqlat | 2023–2025 | 320–800 K (10 isentropes) | ROI + piecewise | NetCDF-4 |

### Download

```bash
# Install required package
pip install zenodo-get

# Download all files (≈ XX GB)
zenodo_get 10.5281/zenodo.20706430
```

Or download individual files directly from the [Zenodo record](https://doi.org/10.5281/zenodo.20706430).

### File naming convention

```
{MODEL}_eqlat_{METHOD}_{YEAR}.nc
# e.g. ERA5_eqlat_roi_2005.nc
```

Each file contains variables `eqlat` and `eqlat_pw` (ROI and piecewise, respectively) on a `(time, theta, lat, lon)` grid, along with `pv_thresholds` used for each level.

### Citation

If you use the released dataset, please cite the Zenodo archive in addition to the [software reference](#reference).

## Reference

Añel JA, Allen DR, Sáenz G, Gimeno L, de la Torre L (2013).  
*Equivalent Latitude Computation Using Regions of Interest (ROI).*  
PLoS ONE 8(9): e72970. https://doi.org/10.1371/journal.pone.0072970

## License

MIT License — see [LICENSE](LICENSE).
