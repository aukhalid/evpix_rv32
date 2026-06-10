#!/usr/bin/env bash
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GDS="$KIT_ROOT/reports/final_gdsii/evpix_asic_sky130hd.gds"
OUT="$KIT_ROOT/reports/layout_screenshot.png"
if [ ! -f "$GDS" ]; then
  echo "ERROR: $GDS not found. Run SKY130 flow and 70_MAKE_GDSII_COPY.sh first."
  exit 1
fi
if ! command -v klayout >/dev/null 2>&1; then
  echo "ERROR: klayout command not found. Use scripts/80_VIEW_LAYOUT.sh manually, or install KLayout."
  exit 1
fi
# KLayout batch screenshot script.
PY="$KIT_ROOT/reports/klayout_export_png.py"
cat > "$PY" <<'PYEOF'
import pya, sys
infile = sys.argv[1]
outfile = sys.argv[2]
app = pya.Application.instance()
win = app.main_window()
win.load_layout(infile, 0)
view = win.current_view()
view.max_hier()
view.zoom_fit()
view.save_image(outfile, 2200, 2200)
PYEOF
klayout -b -r "$PY" -rd dummy=1 "$GDS" "$OUT" || klayout -b -r "$PY" "$GDS" "$OUT"
echo "Saved screenshot: $OUT"
