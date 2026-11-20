#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "$REPO_ROOT"

YOSYS_BIN="${YOSYS:-yosys}"
BUILD_DIR="build/fpga"
FAMILY="xc7"
MODE="all"
SAVE_REPORTS_DIR=""

usage() {
    echo "Usage: $0 [--build-dir <dir>] [--family <xc7|...>] [--mode <all|synth|path>] [--save-reports <dir>]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --build-dir)
            [ $# -ge 2 ] || usage
            BUILD_DIR="$2"
            shift 2
            ;;
        --family)
            [ $# -ge 2 ] || usage
            FAMILY="$2"
            shift 2
            ;;
        --mode)
            [ $# -ge 2 ] || usage
            MODE="$2"
            shift 2
            ;;
        --save-reports)
            [ $# -ge 2 ] || usage
            SAVE_REPORTS_DIR="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

case "$MODE" in
    all|synth|path) ;;
    *) usage ;;
esac

if ! command -v "$YOSYS_BIN" >/dev/null 2>&1; then
    echo "ERROR: Yosys ('$YOSYS_BIN') is not installed or not in PATH." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

MAC_RTL="rtl/mac_unit.v"
PE_RTL="${MAC_RTL} rtl/processing_element.v"
ARRAY_RTL="${PE_RTL} rtl/pe_interconnect.v rtl/systolic_array.v"
CTRL_RTL="rtl/control_fsm.v rtl/systolic_controller.v"
DATA_RTL="rtl/input_buffer.v rtl/output_buffer.v rtl/matrix_interface.v"
TOP_RTL="${ARRAY_RTL} ${CTRL_RTL} ${DATA_RTL} rtl/top_module.v"
TILED_RTL="${ARRAY_RTL} ${CTRL_RTL} phase2/scalability/matrix_tiling_controller.v phase2/scalability/tiled_input_buffer.v phase2/scalability/partial_result_buffer.v phase2/scalability/tiled_gemm_top.v"
PHASE2_TOP_RTL="${ARRAY_RTL} ${CTRL_RTL} phase2/scalability/tiled_input_buffer.v phase2/scalability/matrix_tiling_controller.v phase2/scalability/partial_result_buffer.v phase2/interface/burst_matrix_interface.v phase2/integration/phase2_top_module.v"
BASELINE_RTL="phase2/baseline/sequential_gemm.v"

{
    echo "Timestamp (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Host: $(uname -a)"
    echo "Yosys version: $("$YOSYS_BIN" -V)"
    if command -v iverilog >/dev/null 2>&1; then
        echo "Icarus Verilog: $(iverilog -V 2>/dev/null | head -n 1)"
    fi
    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
        echo "Git commit: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
    fi
    echo "Target family (Yosys): ${FAMILY}"
    echo "Target FPGA part: ${FPGA_TARGET_PART:-UNSPECIFIED}"
    echo "Target board: ${FPGA_BOARD:-UNSPECIFIED}"
} > "${BUILD_DIR}/env_info.txt"

verify_yosys_log() {
    local log_file="$1"
    local label="$2"
    if grep -q "Found and reported 0 problems\." "$log_file"; then
        echo "[PASS] ${label}: Yosys check reported 0 problems."
    else
        echo "[FAIL] ${label}: Yosys did not report 0 problems. Inspect ${log_file}." >&2
        exit 1
    fi
}

run_synth() {
    echo "Running Yosys technology-mapped synthesis (family=${FAMILY})..."

    # 1. Primary integrated module: phase2_top_module (hierarchical without I/O pads)
    "$YOSYS_BIN" -Q -p "
        read_verilog -sv ${PHASE2_TOP_RTL}
        synth_xilinx -family ${FAMILY} -top phase2_top_module -noiopad
        tee -o ${BUILD_DIR}/phase2_top_module_${FAMILY}_hier_stat.txt stat -top phase2_top_module
    " >"${BUILD_DIR}/phase2_top_module_${FAMILY}_hier.log" 2>&1
    verify_yosys_log "${BUILD_DIR}/phase2_top_module_${FAMILY}_hier.log" "phase2_top_module (${FAMILY} hierarchical)"

    # 2. Primary integrated module: phase2_top_module (flattened with I/O pads + JSON + post-synth Verilog)
    "$YOSYS_BIN" -Q -p "
        read_verilog -sv ${PHASE2_TOP_RTL}
        synth_xilinx -family ${FAMILY} -top phase2_top_module -flatten -json ${BUILD_DIR}/phase2_top_module_${FAMILY}_flat.json
        tee -o ${BUILD_DIR}/phase2_top_module_${FAMILY}_flat_stat.txt stat
        write_verilog -noattr ${BUILD_DIR}/phase2_top_module_${FAMILY}_synth.v
    " >"${BUILD_DIR}/phase2_top_module_${FAMILY}_flat.log" 2>&1
    verify_yosys_log "${BUILD_DIR}/phase2_top_module_${FAMILY}_flat.log" "phase2_top_module (${FAMILY} flattened)"

    # 3. Comparative architectures (flattened)
    local name files
    for entry in \
        "top_module|${TOP_RTL}" \
        "tiled_gemm_top|${TILED_RTL}" \
        "sequential_gemm|${BASELINE_RTL}"; do
        name="${entry%%|*}"
        files="${entry#*|}"
        "$YOSYS_BIN" -Q -p "
            read_verilog -sv ${files}
            synth_xilinx -family ${FAMILY} -top ${name} -flatten
            tee -o ${BUILD_DIR}/${name}_${FAMILY}_flat_stat.txt stat
        " >"${BUILD_DIR}/${name}_${FAMILY}_flat.log" 2>&1
        verify_yosys_log "${BUILD_DIR}/${name}_${FAMILY}_flat.log" "${name} (${FAMILY} flattened)"
    done

    # 4. Standalone mac_unit DSP48E1 inspection (register configuration verification)
    "$YOSYS_BIN" -Q -p "
        read_verilog -sv ${MAC_RTL}
        synth_xilinx -family ${FAMILY} -top mac_unit -noiopad
        tee -o ${BUILD_DIR}/mac_unit_dsp_dump.txt dump t:DSP48E1
    " >"${BUILD_DIR}/mac_unit_${FAMILY}.log" 2>&1
    verify_yosys_log "${BUILD_DIR}/mac_unit_${FAMILY}.log" "mac_unit (${FAMILY} DSP check)"

    # 5. Cross-architecture Lattice ECP5 synthesis validation on phase2_top_module
    "$YOSYS_BIN" -Q -p "
        read_verilog -sv ${PHASE2_TOP_RTL}
        synth_ecp5 -top phase2_top_module
        tee -o ${BUILD_DIR}/phase2_top_module_ecp5_stat.txt stat
    " >"${BUILD_DIR}/phase2_top_module_ecp5.log" 2>&1
    verify_yosys_log "${BUILD_DIR}/phase2_top_module_ecp5.log" "phase2_top_module (ecp5 cross-check)"
}

run_path_analysis() {
    echo "Running Yosys pre-mapping structural longest topological path (ltp -noff)..."
    local name files
    for entry in \
        "phase2_top_module|${PHASE2_TOP_RTL}" \
        "tiled_gemm_top|${TILED_RTL}" \
        "top_module|${TOP_RTL}" \
        "sequential_gemm|${BASELINE_RTL}"; do
        name="${entry%%|*}"
        files="${entry#*|}"
        "$YOSYS_BIN" -Q -p "
            read_verilog -sv ${files}
            hierarchy -check -top ${name}
            proc
            flatten
            opt
            check
            ltp -noff
        " >"${BUILD_DIR}/${name}_rtl_ltp.txt" 2>&1
        verify_yosys_log "${BUILD_DIR}/${name}_rtl_ltp.txt" "${name} (RTL LTP check)"
    done
}

if [ "$MODE" = "synth" ] || [ "$MODE" = "all" ]; then
    run_synth
fi

if [ "$MODE" = "path" ] || [ "$MODE" = "all" ]; then
    run_path_analysis
fi

if [ -n "$SAVE_REPORTS_DIR" ]; then
    mkdir -p "$SAVE_REPORTS_DIR"
    python3 "${SCRIPT_DIR}/parse_yosys_reports.py" --build-dir "$BUILD_DIR" --family "$FAMILY" --print none
    cp "${BUILD_DIR}/utilization_summary.txt" "${SAVE_REPORTS_DIR}/utilization_summary.txt"
    cp "${BUILD_DIR}/timing_and_path_analysis.txt" "${SAVE_REPORTS_DIR}/timing_and_path_analysis.txt"
    echo "Saved summary reports to ${SAVE_REPORTS_DIR}/"
fi
