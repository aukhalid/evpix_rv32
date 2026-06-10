#!/usr/bin/env bash
# EVPIX ASIC one-command SKY130HD flow runner, v15.
# Fixes: fast IPU + hierarchical synthesis + OpenROAD read_verilog patch.
# Important: only Yosys synthesis Tcl scripts get read_verilog -sv.
# OpenROAD floorplan/place Tcl scripts must use plain read_verilog filename.
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_ROOT"
mkdir -p reports

# ------------------------------------------------------------
# 1) Locate OpenROAD-flow-scripts
# ------------------------------------------------------------
ORFS_ROOT="${OPENROAD_FLOW_ROOT:-}"
if [ -z "${ORFS_ROOT}" ]; then
  for d in \
    "$HOME/Desktop/OpenROAD-flow-scripts" \
    "$HOME/OpenROAD-flow-scripts" \
    "$HOME/openroad-flow-scripts" \
    "$HOME/tools/OpenROAD-flow-scripts" \
    "/opt/OpenROAD-flow-scripts" \
    "/usr/local/OpenROAD-flow-scripts"; do
    if [ -d "$d/flow" ]; then
      ORFS_ROOT="$d"
      break
    fi
  done
fi

if [ -z "${ORFS_ROOT}" ] || [ ! -d "$ORFS_ROOT/flow" ]; then
  echo "ERROR: Could not find OpenROAD-flow-scripts."
  echo "Run this to locate it:"
  echo "  find ~ /opt /usr/local -type d -name OpenROAD-flow-scripts 2>/dev/null"
  echo "Then rerun with:"
  echo "  export OPENROAD_FLOW_ROOT=/path/to/OpenROAD-flow-scripts"
  echo "  bash scripts/00_RUN_ME_FIRST_SKY130_FULL.sh"
  exit 1
fi

export OPENROAD_FLOW_ROOT="$ORFS_ROOT"
echo "$OPENROAD_FLOW_ROOT" > "$KIT_ROOT/.orfs_root"

LOG="$KIT_ROOT/reports/run_sky130_V16_no_final_report.log"
exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo "EVPIX ASIC SKY130HD FULL FLOW V16 NO FINAL_REPORT GDS EXPORT"
echo "KIT_ROOT=$KIT_ROOT"
echo "OPENROAD_FLOW_ROOT=$OPENROAD_FLOW_ROOT"
echo "LOG=$LOG"
echo "============================================================"

# ------------------------------------------------------------
# 2) Locate/install/repair OSS CAD Suite for modern Yosys
# ------------------------------------------------------------
OSS_DIR="${OSS_CAD_SUITE_ROOT:-$HOME/tools/oss-cad-suite}"
OSS_TGZ_CANDIDATE=""

find_local_oss_tgz() {
  for f in "$HOME/Downloads"/oss-cad-suite-linux-x64-*.tgz \
           "$HOME/Downloads"/oss-cad-suite-linux-x64.tgz \
           "/tmp"/oss-cad-suite-linux-x64*.tgz; do
    if [ -f "$f" ]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

is_yosys_corrupt() {
  local y="$OSS_DIR/bin/yosys"
  if [ ! -x "$y" ]; then
    echo "Yosys is missing or not executable at $y" >&2
    return 0
  fi

  # v7 fix:
  # OSS CAD Suite can legitimately ship bin/yosys as a shell wrapper.
  # Do NOT reject it just because it starts with #!/bin/sh.
  # Only reject wrappers that look like the broken recursive EVPIX wrapper,
  # or any yosys that fails `yosys -V` quickly.
  if head -n 20 "$y" 2>/dev/null | grep -q 'exec "$HOME/tools/oss-cad-suite/bin/yosys"'; then
    echo "Detected old recursive EVPIX wrapper at $y; treating as corrupted." >&2
    return 0
  fi
  if head -n 20 "$y" 2>/dev/null | grep -q 'exec .*/oss-cad-suite/bin/yosys'; then
    echo "Detected old recursive EVPIX wrapper at $y; treating as corrupted." >&2
    return 0
  fi

  if command -v timeout >/dev/null 2>&1; then
    if ! timeout 12 "$y" -V >/tmp/evpix_yosys_v.log 2>&1; then
      echo "Yosys version check failed; treating OSS CAD Suite as corrupted." >&2
      cat /tmp/evpix_yosys_v.log >&2 || true
      return 0
    fi
  else
    if ! "$y" -V >/tmp/evpix_yosys_v.log 2>&1; then
      echo "Yosys version check failed; treating OSS CAD Suite as corrupted." >&2
      cat /tmp/evpix_yosys_v.log >&2 || true
      return 0
    fi
  fi

  if ! grep -q "Yosys" /tmp/evpix_yosys_v.log 2>/dev/null; then
    echo "Yosys -V did not print a Yosys version; treating as corrupted." >&2
    cat /tmp/evpix_yosys_v.log >&2 || true
    return 0
  fi

  echo "OSS CAD Suite yosys version check passed: $(head -n 1 /tmp/evpix_yosys_v.log)"
  return 1
}

install_oss() {
  echo "Installing/reinstalling OSS CAD Suite into: $OSS_DIR"
  mkdir -p "$HOME/tools"

  if OSS_TGZ_CANDIDATE="$(find_local_oss_tgz)"; then
    echo "Using local OSS CAD Suite archive: $OSS_TGZ_CANDIDATE"
    TMP_TGZ="$OSS_TGZ_CANDIDATE"
  else
    echo "Downloading latest OSS CAD Suite Linux x64 archive..."
    TMP_TGZ="/tmp/oss-cad-suite-linux-x64.tgz"
    python3 - <<'PY' >/tmp/evpix_oss_url.txt
import json, urllib.request, sys
url = 'https://api.github.com/repos/YosysHQ/oss-cad-suite-build/releases/latest'
try:
    data = json.load(urllib.request.urlopen(url, timeout=60))
except Exception as e:
    sys.exit('ERROR: Could not query OSS CAD Suite release: %s' % e)
for a in data.get('assets', []):
    name = a.get('name', '')
    if name.startswith('oss-cad-suite-linux-x64-') and name.endswith('.tgz'):
        print(a['browser_download_url'])
        break
else:
    sys.exit('ERROR: No linux-x64 OSS CAD Suite asset found')
PY
    ASSET_URL="$(cat /tmp/evpix_oss_url.txt)"
    echo "Asset: $ASSET_URL"
    if command -v wget >/dev/null 2>&1; then
      wget -O "$TMP_TGZ" "$ASSET_URL"
    else
      curl -L -o "$TMP_TGZ" "$ASSET_URL"
    fi
  fi

  rm -rf "$OSS_DIR"
  tar -xzf "$TMP_TGZ" -C "$HOME/tools"
  if [ ! -f "$OSS_DIR/environment" ] || [ ! -x "$OSS_DIR/bin/yosys" ]; then
    echo "ERROR: OSS CAD Suite extraction did not create expected files."
    echo "Expected: $OSS_DIR/environment and $OSS_DIR/bin/yosys"
    exit 1
  fi
}

if [ ! -f "$OSS_DIR/environment" ] || is_yosys_corrupt; then
  install_oss
fi

if is_yosys_corrupt; then
  echo "ERROR: OSS CAD Suite yosys is still corrupted after reinstall."
  exit 1
fi

# Use OSS CAD Suite for modern Yosys/OpenROAD.
source "$OSS_DIR/environment"

# ------------------------------------------------------------
# 3) Install PyYAML into local vendor folder and export PYTHONPATH
# ------------------------------------------------------------
echo "Using python3: $(which python3)"
python3 --version

echo "Using yosys: $(which yosys)"
"$OSS_DIR/bin/yosys" -V

PYDEPS="$KIT_ROOT/.pydeps"
mkdir -p "$PYDEPS"

if [ ! -d "$PYDEPS/yaml" ]; then
  echo "Installing PyYAML into local vendor folder: $PYDEPS"
  python3 -m ensurepip --upgrade >/tmp/evpix_ensurepip.log 2>&1 || true
  python3 -m pip install --upgrade --target "$PYDEPS" PyYAML pyyaml | tee "$KIT_ROOT/reports/pip_pyyaml_install.log"
else
  echo "Using existing local PyYAML folder: $PYDEPS/yaml"
fi

export PYTHONPATH="$PYDEPS:${PYTHONPATH:-}"
echo "PYTHONPATH=$PYTHONPATH"
python3 - <<PY
import sys
print('Python executable:', sys.executable)
print('First sys.path entries:', sys.path[:5])
import yaml
print('YAML OK:', yaml.__version__, 'from', yaml.__file__)
PY

# ------------------------------------------------------------
# 4) Patch ORFS tool expected paths safely
# ------------------------------------------------------------
echo "Creating ORFS tool wrappers safely..."
mkdir -p "$OPENROAD_FLOW_ROOT/tools/install/yosys/bin"
ORFS_YOSYS="$OPENROAD_FLOW_ROOT/tools/install/yosys/bin/yosys"

# Critical: remove any old symlink first. Otherwise cat > may overwrite the real OSS yosys binary.
rm -f "$ORFS_YOSYS"
cat > "$ORFS_YOSYS" <<EOS
#!/usr/bin/env bash
export OSS_CAD_SUITE_ROOT="$OSS_DIR"
source "$OSS_DIR/environment"
if [ -n "\${EVPIX_PYDEPS:-}" ]; then
  export PYTHONPATH="\$EVPIX_PYDEPS:\${PYTHONPATH:-}"
fi
exec "$OSS_DIR/bin/yosys" "\$@"
EOS
chmod +x "$ORFS_YOSYS"
export EVPIX_PYDEPS="$PYDEPS"

mkdir -p "$OPENROAD_FLOW_ROOT/tools/install/OpenROAD/bin"
ORFS_OPENROAD="$OPENROAD_FLOW_ROOT/tools/install/OpenROAD/bin/openroad"
rm -f "$ORFS_OPENROAD"
if [ -x "$OSS_DIR/bin/openroad" ]; then
  cat > "$ORFS_OPENROAD" <<EOS
#!/usr/bin/env bash
export OSS_CAD_SUITE_ROOT="$OSS_DIR"
source "$OSS_DIR/environment"
export PYTHONPATH="$PYDEPS:\${PYTHONPATH:-}"
exec "$OSS_DIR/bin/openroad" "\$@"
EOS
  chmod +x "$ORFS_OPENROAD"
elif command -v openroad >/dev/null 2>&1; then
  ln -sf "$(command -v openroad)" "$ORFS_OPENROAD"
elif [ -x /usr/local/bin/openroad ]; then
  ln -sf /usr/local/bin/openroad "$ORFS_OPENROAD"
else
  echo "WARNING: openroad command not found yet. ORFS may fail later if OpenROAD is missing."
fi

"$ORFS_YOSYS" -V
if [ -x "$ORFS_OPENROAD" ]; then
  "$ORFS_OPENROAD" -version || true
fi

# ------------------------------------------------------------
# 5) Patch old ORFS scripts safely
# ------------------------------------------------------------
echo "Patching ORFS Tcl scripts safely..."
python3 - <<'PY_ORFS_PATCH'
from pathlib import Path
import re, os

root = Path(os.environ["OPENROAD_FLOW_ROOT"]) / "flow" / "scripts"

# Yosys Tcl files need SystemVerilog mode.
# OpenROAD floorplan/place/CTS/route Tcl files do NOT accept -sv in read_verilog.
# Earlier kits patched every Tcl file and caused:
#   floorplan.tcl, 4 wrong # args: should be "read_verilog filename"
yosys_tcl_names = {
    "synth.tcl",
    "synth_canonicalize.tcl",
}

for p in root.glob("*.tcl"):
    txt = p.read_text()
    if "read_verilog" not in txt:
        continue
    old = txt

    if p.name in yosys_tcl_names:
        # Add -sv only if this read_verilog command does not already have it.
        txt = re.sub(r'\bread_verilog(?![^\n;]*\s-sv\b)', 'read_verilog -sv', txt)
    else:
        # Restore OpenROAD/OpenSTA syntax. These tools expect read_verilog filename.
        txt = re.sub(r'\bread_verilog\s+-sv\b', 'read_verilog', txt)

    if txt != old:
        bak = p.with_suffix(p.suffix + ".evpix_v14_bak")
        if not bak.exists():
            bak.write_text(old)
        p.write_text(txt)
        print("patched", p)

print("Current read_verilog commands after v14 patch:")
for p in sorted(root.glob("*.tcl")):
    txt = p.read_text()
    if "read_verilog" in txt:
        for line in txt.splitlines():
            if "read_verilog" in line:
                print(f"{p.name}: {line.strip()}")
PY_ORFS_PATCH
SYNTH_SH="$OPENROAD_FLOW_ROOT/flow/scripts/synth.sh"
if [ -f "$SYNTH_SH" ] && ! grep -q 'YOSYS_FLAGS:=' "$SYNTH_SH"; then
  sed -i '2i : "${YOSYS_FLAGS:=}"' "$SYNTH_SH"
  echo "patched $SYNTH_SH for default YOSYS_FLAGS"
fi

for sh in "$OPENROAD_FLOW_ROOT"/flow/scripts/*.sh; do
  [ -f "$sh" ] || continue
  if grep -q 'set -.*u' "$sh" && ! grep -q 'EVPIX_DEFAULTS_INSERTED' "$sh"; then
    sed -i '2i # EVPIX_DEFAULTS_INSERTED\n: "${YOSYS_FLAGS:=}"\n: "${OPENROAD_ARGS:=}"\n: "${OPENROAD_CMD:=openroad}"' "$sh" || true
  fi
done

# ------------------------------------------------------------
# 6) Make EVPIX file list compatible with this ORFS version
# ------------------------------------------------------------
sed -i 's/^VERILOG_FILES[[:space:]]*=/export VERILOG_FILES =/' "$KIT_ROOT/flow/rtl_files.mk"

# ------------------------------------------------------------
# 7) Install EVPIX design into ORFS
# ------------------------------------------------------------
bash "$KIT_ROOT/scripts/02_install_designs_into_orfs.sh"

# ------------------------------------------------------------
# 8) Smoke tests
# ------------------------------------------------------------
echo "Running SystemVerilog parser smoke test..."
"$ORFS_YOSYS" -p "read_verilog -sv rtl/common/main_control.sv; hierarchy -check -top main_control" | tee "$KIT_ROOT/reports/yosys_main_control_test.log"

python3 - <<PY
import yaml
print('ORFS Python YAML test OK:', yaml.__version__)
PY

# ------------------------------------------------------------
# 9) Clean previous failed SKY130 run
# ------------------------------------------------------------
rm -rf "$OPENROAD_FLOW_ROOT/flow/logs/sky130hd/evpix_asic"
rm -rf "$OPENROAD_FLOW_ROOT/flow/results/sky130hd/evpix_asic"
rm -rf "$OPENROAD_FLOW_ROOT/flow/reports/sky130hd/evpix_asic"
rm -rf "$OPENROAD_FLOW_ROOT/flow/objects/sky130hd/evpix_asic"


# V14: force fast/hierarchical synthesis settings in installed config.
# This prevents the flat full-chip ABC hang seen in v10.
INSTALLED_CFG="$OPENROAD_FLOW_ROOT/flow/designs/sky130hd/evpix_asic/config.mk"
if [ -f "$INSTALLED_CFG" ]; then
  grep -q "SYNTH_HIERARCHICAL" "$INSTALLED_CFG" || echo "export SYNTH_HIERARCHICAL = 1" >> "$INSTALLED_CFG"
  grep -q "ABC_AREA" "$INSTALLED_CFG" || echo "export ABC_AREA = 1" >> "$INSTALLED_CFG"
  grep -q "ABC_CLOCK_PERIOD_IN_PS" "$INSTALLED_CFG" || echo "export ABC_CLOCK_PERIOD_IN_PS = 100000" >> "$INSTALLED_CFG"
fi

# ------------------------------------------------------------
# 10) Run SKY130HD until routed/fill ODB, then export GDS from ODB
# ------------------------------------------------------------
export PYTHONPATH="$PYDEPS:${PYTHONPATH:-}"
bash "$KIT_ROOT/scripts/10_run_sky130hd.sh"

# ------------------------------------------------------------
# 11) Collect outputs, including explicit GDSII/GDS2 copies
# ------------------------------------------------------------
bash "$KIT_ROOT/scripts/30_collect_reports.sh" || true
bash "$KIT_ROOT/scripts/70_MAKE_GDSII_COPY.sh"

FINAL_DIR="$OPENROAD_FLOW_ROOT/flow/results/sky130hd/evpix_asic/base"
REPORT_DIR="$OPENROAD_FLOW_ROOT/flow/reports/sky130hd/evpix_asic/base"

{
  echo "============================================================"
  echo "SKY130HD FLOW FINISHED"
  echo "Final result folder: $FINAL_DIR"
  echo "Report folder:       $REPORT_DIR"
  echo ""
  echo "Final layout/netlist files from ORFS:"
  find "$FINAL_DIR" -type f \( -name "*.gds" -o -name "*.gdsii" -o -name "*.gds2" -o -name "*.def" -o -name "*.v" -o -name "*.sdc" -o -name "*.spef" -o -name "*.odb" \) || true
  echo ""
  echo "Copied GDSII/GDS2 files:"
  find "$KIT_ROOT/reports/final_gdsii" -type f 2>/dev/null || true
  echo "============================================================"
} | tee "$KIT_ROOT/reports/FINAL_OUTPUTS.txt"
