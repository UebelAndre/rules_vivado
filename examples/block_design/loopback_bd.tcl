# Minimal block design — one BD, zero IP. Real designs would
# `create_bd_cell` a Zynq PS, AXI interconnect, and peripheral IPs
# here; keeping it empty makes `bazel build :loopback_bd` finish in
# seconds and lets this file serve as a syntactic sketch of the
# vivado_block_design contract.
create_bd_design loopback
save_bd_design
close_bd_design [get_bd_designs loopback]
