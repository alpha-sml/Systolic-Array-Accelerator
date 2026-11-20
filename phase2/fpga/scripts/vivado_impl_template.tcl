# vivado_impl_template.tcl
# Reference Vivado non-project batch implementation script for phase2_top_module.
# NOT EXECUTED in the current evaluation environment (Vivado unavailable, target
# FPGA part and official board XDC constraints unspecified).
#
# Usage:
#   vivado -mode batch -source phase2/fpga/scripts/vivado_impl_template.tcl \
#       -tclargs <timing|bitstream> <part> <xdc_file> <out_dir>

if {$argc < 4} {
    puts stderr "ERROR: Expected 4 arguments: <timing|bitstream> <part> <xdc_file> <out_dir>"
    exit 1
}

set impl_mode [lindex $argv 0]
set target_part [lindex $argv 1]
set xdc_file [lindex $argv 2]
set out_dir [lindex $argv 3]

if {$impl_mode ne "timing" && $impl_mode ne "bitstream"} {
    puts stderr "ERROR: First argument must be 'timing' or 'bitstream', got '$impl_mode'."
    exit 1
}

if {$target_part eq "" || $target_part eq "UNSPECIFIED"} {
    puts stderr "ERROR: Target FPGA part is UNSPECIFIED. Pass a real FPGA part number."
    exit 1
}

if {$xdc_file eq "" || ![file exists $xdc_file]} {
    puts stderr "ERROR: Official board/clock XDC file '$xdc_file' not found. Do not invent pinouts."
    exit 1
}

file mkdir $out_dir

set rtl_files [list \
    "rtl/mac_unit.v" \
    "rtl/processing_element.v" \
    "rtl/pe_interconnect.v" \
    "rtl/systolic_array.v" \
    "rtl/control_fsm.v" \
    "rtl/systolic_controller.v" \
    "phase2/scalability/tiled_input_buffer.v" \
    "phase2/scalability/matrix_tiling_controller.v" \
    "phase2/scalability/partial_result_buffer.v" \
    "phase2/interface/burst_matrix_interface.v" \
    "phase2/integration/phase2_top_module.v" \
]

foreach f $rtl_files {
    if {![file exists $f]} {
        puts stderr "ERROR: Missing RTL dependency '$f'."
        exit 1
    }
    read_verilog -sv $f
}

read_xdc $xdc_file

synth_design -top phase2_top_module -part $target_part
write_checkpoint -force "$out_dir/post_synth.dcp"
report_utilization -file "$out_dir/post_synth_utilization.rpt"
report_timing_summary -file "$out_dir/post_synth_timing.rpt"

opt_design
place_design
route_design

write_checkpoint -force "$out_dir/post_route.dcp"
report_utilization -file "$out_dir/post_route_utilization.rpt"
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 10 -file "$out_dir/post_route_timing_summary.rpt"
report_clock_utilization -file "$out_dir/post_route_clock_util.rpt"
report_power -file "$out_dir/post_route_power.rpt"

if {$impl_mode eq "bitstream"} {
    write_bitstream -force "$out_dir/phase2_top_module.bit"
}

puts "Vivado non-project flow ($impl_mode) completed for part $target_part in $out_dir."
