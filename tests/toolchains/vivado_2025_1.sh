#!/usr/bin/env bash
# Test shim. See `vivado_2024_1.sh` for the PATH-restoration contract.
# The 2025.1 install layout in kode's fpga container is
# `/tools/Xilinx/2025.1/Vivado/` — version at the top level, not
# nested under `/tools/Xilinx/Vivado/<ver>/` like the 2024.2 install.
export PATH="/usr/local/bin:/tools/Xilinx/2025.1/Vivado/bin:${PATH:-/usr/bin:/bin}"
exec vivado "$@"
