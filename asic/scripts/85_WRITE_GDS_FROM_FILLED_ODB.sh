#!/usr/bin/env bash
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -f "$KIT_ROOT/.orfs_root" ]; then
  ORFS_ROOT="$(cat "$KIT_ROOT/.orfs_root")"
else
  ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"
fi
if [ -z "${ORFS_ROOT:-}" ] || [ ! -d "$ORFS_ROOT/flow" ]; then
  echo "ERROR: OPENROAD_FLOW_ROOT unknown. Run 00_RUN_ME_FIRST_SKY130_FULL.sh first, or export OPENROAD_FLOW_ROOT."
  exit 1
fi

OSS_DIR="${OSS_CAD_SUITE_ROOT:-$HOME/tools/oss-cad-suite}"
if [ -f "$OSS_DIR/environment" ]; then
  # shellcheck disable=SC1090
  source "$OSS_DIR/environment"
fi
if [ -d "$KIT_ROOT/.pydeps" ]; then
  export PYTHONPATH="$KIT_ROOT/.pydeps:${PYTHONPATH:-}"
fi

OPENROAD_EXE="$ORFS_ROOT/tools/install/OpenROAD/bin/openroad"
if [ ! -x "$OPENROAD_EXE" ]; then
  OPENROAD_EXE="$(command -v openroad || true)"
fi
if [ -z "$OPENROAD_EXE" ] || [ ! -x "$OPENROAD_EXE" ]; then
  echo "ERROR: openroad executable not found."
  exit 1
fi

RES="$ORFS_ROOT/flow/results/sky130hd/evpix_asic/base"
ODB=""
for f in "$RES/6_1_fill.odb" "$RES/5_route.odb" "$RES/5_3_fillcell.odb" "$RES/5_2_TritonRoute.odb" "$RES/5_1_grt.odb"; do
  if [ -f "$f" ]; then
    ODB="$f"
    break
  fi
done
if [ -z "$ODB" ]; then
  echo "ERROR: No routed/fill ODB found in $RES"
  find "$RES" -maxdepth 1 -type f | sort || true
  exit 1
fi

OUT="$KIT_ROOT/reports/final_gdsii"
mkdir -p "$OUT"
mkdir -p "$KIT_ROOT/reports"
PLAT="$ORFS_ROOT/flow/platforms/sky130hd"
DEF_OUT="$OUT/evpix_asic_sky130hd.def"
ODB_OUT="$OUT/evpix_asic_sky130hd.odb"
GDS_OUT="$OUT/evpix_asic_sky130hd.gds"

# 1) Always export DEF and ODB from the already routed database.
TCL_OR="$KIT_ROOT/reports/export_def_odb_try_gds.tcl"
cat > "$TCL_OR" <<'TCL_EOF'
set odb_file $::env(EVPIX_ODB)
set out_dir  $::env(EVPIX_GDS_OUT)
set plat_dir $::env(EVPIX_SKY130_PLATFORM)

puts "Reading routed/fill ODB: $odb_file"
read_db $odb_file
file mkdir $out_dir

set def_out "$out_dir/evpix_asic_sky130hd.def"
set odb_out "$out_dir/evpix_asic_sky130hd.odb"
set gds_out "$out_dir/evpix_asic_sky130hd.gds"

puts "Writing DEF: $def_out"
write_def $def_out
puts "Writing ODB: $odb_out"
write_db $odb_out

# Some older OpenROAD builds do not include the write_gds command.
# Do not fail here; external KLayout/Magic fallback will handle GDS.
if {[llength [info commands write_gds]] == 0} {
  puts "INFO: this OpenROAD build has no write_gds command; using external GDS fallback."
  exit
}

set gds_files [list]
foreach pattern [list \
  "$plat_dir/gds/*.gds" \
  "$plat_dir/gds/*.gds.gz" \
  "$plat_dir/gds/*/*.gds" \
  "$plat_dir/gds/*/*.gds.gz" \
] {
  foreach g [glob -nocomplain $pattern] {
    lappend gds_files $g
  }
}
puts "Standard-cell GDS merge file count: [llength $gds_files]"

if {[llength $gds_files] > 0} {
  if {[catch {write_gds -merge $gds_files $gds_out} err1]} {
    puts "write_gds -merge failed: $err1"
    if {[catch {write_gds -merge_files $gds_files $gds_out} err2]} {
      puts "write_gds -merge_files failed: $err2"
      puts "Falling back to write_gds without merge."
      write_gds $gds_out
    }
  }
} else {
  puts "WARNING: no standard-cell GDS merge files found; writing GDS without merge."
  write_gds $gds_out
}
TCL_EOF

export EVPIX_ODB="$ODB"
export EVPIX_GDS_OUT="$OUT"
export EVPIX_SKY130_PLATFORM="$PLAT"
"$OPENROAD_EXE" -exit "$TCL_OR" 2>&1 | tee "$KIT_ROOT/reports/export_def_odb_try_gds.log"

if [ -s "$GDS_OUT" ]; then
  echo "GDS created by OpenROAD: $GDS_OUT"
else
  echo "OpenROAD did not create GDS. Trying external GDS writers..."
fi

# Gather LEF/GDS dependencies for external conversion.
TECH_LEF="$PLAT/lef/sky130_fd_sc_hd.tlef"
MERGED_LEF="$PLAT/lef/sky130_fd_sc_hd_merged.lef"
STD_GDS_LIST="$OUT/stdcell_gds_files.txt"
find "$PLAT/gds" -type f \( -name "*.gds" -o -name "*.gds.gz" \) 2>/dev/null | sort > "$STD_GDS_LIST" || true
STD_GDS_COUNT="$(wc -l < "$STD_GDS_LIST" | tr -d ' ')"
echo "Standard-cell GDS files found for external merge: $STD_GDS_COUNT"

# 2) KLayout fallback. This is the most common open-source way to stream DEF+LEF to GDS.
if [ ! -s "$GDS_OUT" ] && command -v klayout >/dev/null 2>&1; then
  echo "Trying KLayout DEF/LEF -> GDS export..."
  KL_PY="$KIT_ROOT/reports/klayout_def_to_gds.py"
  cat > "$KL_PY" <<'PY_EOF'
import os, sys, glob
try:
    import pya
except Exception as e:
    print("ERROR: KLayout Python module pya unavailable:", e)
    sys.exit(2)

out_dir = os.environ["EVPIX_GDS_OUT"]
def_file = os.environ["EVPIX_DEF"]
tech_lef = os.environ.get("EVPIX_TECH_LEF", "")
merged_lef = os.environ.get("EVPIX_MERGED_LEF", "")
gds_out = os.path.join(out_dir, "evpix_asic_sky130hd.gds")
std_list = os.environ.get("EVPIX_STDCELL_GDS_LIST", "")

std_gds = []
if std_list and os.path.exists(std_list):
    with open(std_list) as f:
        std_gds = [x.strip() for x in f if x.strip()]

print("KLayout export")
print("  DEF:", def_file)
print("  TECH LEF:", tech_lef)
print("  MERGED LEF:", merged_lef)
print("  stdcell GDS count:", len(std_gds))
print("  OUT:", gds_out)

attempts = [
    [x for x in [tech_lef, merged_lef, def_file] if x and os.path.exists(x)] + std_gds,
    std_gds + [x for x in [tech_lef, merged_lef, def_file] if x and os.path.exists(x)],
]

last_err = None
for idx, files in enumerate(attempts, 1):
    try:
        ly = pya.Layout()
        ly.dbu = 0.001
        print("Attempt", idx)
        for path in files:
            print("  reading", path)
            ly.read(path)
        if ly.cells() == 0:
            raise RuntimeError("KLayout loaded zero cells")
        ly.write(gds_out)
        if os.path.exists(gds_out) and os.path.getsize(gds_out) > 0:
            print("KLayout created", gds_out, "size", os.path.getsize(gds_out))
            sys.exit(0)
        raise RuntimeError("GDS not created or empty")
    except Exception as e:
        last_err = e
        print("Attempt", idx, "failed:", repr(e))

print("ERROR: all KLayout attempts failed:", repr(last_err))
sys.exit(1)
PY_EOF
  export EVPIX_DEF="$DEF_OUT"
  export EVPIX_TECH_LEF="$TECH_LEF"
  export EVPIX_MERGED_LEF="$MERGED_LEF"
  export EVPIX_STDCELL_GDS_LIST="$STD_GDS_LIST"
  if klayout -b -r "$KL_PY" 2>&1 | tee "$KIT_ROOT/reports/klayout_gds_export.log"; then
    echo "KLayout GDS export completed."
  else
    echo "KLayout GDS export failed; see reports/klayout_gds_export.log"
  fi
fi

# 3) Magic fallback if installed. This is less precise but can often create a viewable GDS from DEF.
if [ ! -s "$GDS_OUT" ] && command -v magic >/dev/null 2>&1; then
  echo "Trying Magic DEF/LEF -> GDS export..."
  MAGIC_RC=""
  MAGIC_RC="$(find "$PLAT" -maxdepth 3 -type f \( -name "*.magicrc" -o -name "magicrc" \) | head -1 || true)"
  MAGIC_TCL="$KIT_ROOT/reports/magic_def_to_gds.tcl"
  {
    echo "drc off"
    if [ -f "$TECH_LEF" ]; then echo "lef read $TECH_LEF"; fi
    if [ -f "$MERGED_LEF" ]; then echo "lef read $MERGED_LEF"; fi
    echo "def read $DEF_OUT"
    echo "load evpix_asic_core_top"
    echo "select top cell"
    echo "gds write $GDS_OUT"
    echo "quit -noprompt"
  } > "$MAGIC_TCL"
  if [ -n "$MAGIC_RC" ]; then
    magic -dnull -noconsole -rcfile "$MAGIC_RC" "$MAGIC_TCL" 2>&1 | tee "$KIT_ROOT/reports/magic_gds_export.log" || true
  else
    magic -dnull -noconsole "$MAGIC_TCL" 2>&1 | tee "$KIT_ROOT/reports/magic_gds_export.log" || true
  fi
fi

# Finalize outputs.
if [ -s "$GDS_OUT" ]; then
  cp -f "$GDS_OUT" "$OUT/evpix_asic_sky130hd.gdsii"
  cp -f "$GDS_OUT" "$OUT/evpix_asic_sky130hd.gds2"
  cat > "$KIT_ROOT/reports/FINAL_OUTPUTS.txt" <<EOF2
============================================================
EVPIX SKY130HD GDSII EXPORT FINISHED
============================================================
Routed/fill ODB source:
$ODB

Final exported layout files:
$OUT/evpix_asic_sky130hd.gds
$OUT/evpix_asic_sky130hd.gdsii
$OUT/evpix_asic_sky130hd.gds2
$OUT/evpix_asic_sky130hd.def
$OUT/evpix_asic_sky130hd.odb

Notes:
- .gds, .gdsii, and .gds2 are copies of the same GDSII/GDS2 layout stream.
- This export intentionally skips the heavy final_report stage that caused VM signal-9/OOM.
============================================================
EOF2
  echo "GDSII/GDS2 layout export complete:"
  ls -lh "$OUT"/evpix_asic_sky130hd.*
  echo
  echo "Summary written to: $KIT_ROOT/reports/FINAL_OUTPUTS.txt"
  exit 0
fi

cat > "$KIT_ROOT/reports/FINAL_OUTPUTS.txt" <<EOF2
============================================================
EVPIX ROUTED LAYOUT EXISTS, BUT GDS EXPORT NEEDS A WRITER
============================================================
Routed/fill ODB source:
$ODB

Exported physical files available now:
$OUT/evpix_asic_sky130hd.def
$OUT/evpix_asic_sky130hd.odb

GDS was not created because this OpenROAD build has no write_gds command and no working KLayout/Magic fallback was available.
Install KLayout or Magic, then rerun:
  bash scripts/70_MAKE_GDSII_COPY.sh

Useful logs:
$KIT_ROOT/reports/export_def_odb_try_gds.log
$KIT_ROOT/reports/klayout_gds_export.log
$KIT_ROOT/reports/magic_gds_export.log
============================================================
EOF2

echo "ERROR: Could not create GDS with available tools."
echo "But the routed layout has been exported as DEF/ODB:"
ls -lh "$OUT"/evpix_asic_sky130hd.def "$OUT"/evpix_asic_sky130hd.odb 2>/dev/null || true
echo
echo "Install KLayout or Magic, then rerun: bash scripts/70_MAKE_GDSII_COPY.sh"
echo "Summary written to: $KIT_ROOT/reports/FINAL_OUTPUTS.txt"
exit 2
