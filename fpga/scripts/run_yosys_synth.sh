#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

MAC_RTL="rtl/core/mac_unit.v"
PE_RTL="${MAC_RTL} rtl/core/processing_element.v"
ARRAY_RTL="${PE_RTL} rtl/core/pe_interconnect.v rtl/core/systolic_array.v"
CTRL_RTL="rtl/core/control_fsm.v rtl/core/systolic_controller.v"
DATA_RTL="rtl/interface/input_buffer.v rtl/interface/output_buffer.v rtl/interface/matrix_interface.v"
TOP_RTL="${ARRAY_RTL} ${CTRL_RTL} ${DATA_RTL} rtl/core/top_module.v"
TILED_RTL="${ARRAY_RTL} ${CTRL_RTL} rtl/extensions/matrix_tiling_controller.v rtl/extensions/tiled_input_buffer.v rtl/extensions/partial_result_buffer.v rtl/extensions/tiled_gemm_top.v"
INTEGRATED_TOP_RTL="${ARRAY_RTL} ${CTRL_RTL} rtl/extensions/tiled_input_buffer.v rtl/extensions/matrix_tiling_controller.v rtl/extensions/partial_result_buffer.v rtl/extensions/burst_matrix_interface.v rtl/extensions/integrated_gemm_top.v"
BASELINE_RTL="rtl/baseline/sequential_gemm.v"

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
    if grep -Eiq "(^|Warning:[[:space:]]*)Latch inferred" "$log_file"; then
        echo "[FAIL] ${label}: Yosys inferred a latch. Inspect ${log_file}." >&2
        tail -n 40 "$log_file" >&2 || true
        exit 1
    fi
    if grep -q "Found and reported 0 problems\." "$log_file"; then
        echo "[PASS] ${label}: Yosys check reported 0 problems."
    else
        echo "[FAIL] ${label}: Yosys did not report 0 problems. Inspect ${log_file}." >&2
        tail -n 40 "$log_file" >&2 || true
        exit 1
    fi
}

run_yosys_cmd() {
    local log_file="$1"
    local label="$2"
    local script="$3"
    if ! "$YOSYS_BIN" -Q -p "$script" >"$log_file" 2>&1; then
        local rc=$?
        echo "[FAIL] ${label}: Yosys exited with status ${rc}. Inspect ${log_file}." >&2
        tail -n 40 "$log_file" >&2 || true
        exit "$rc"
    fi
    verify_yosys_log "$log_file" "$label"
}

run_synth() {
    echo "Running Yosys technology-mapped synthesis (family=${FAMILY})..."

    # 1. Primary integrated module: integrated_gemm_top (hierarchical without I/O pads)
    run_yosys_cmd "${BUILD_DIR}/integrated_gemm_top_${FAMILY}_hier.log" \
        "integrated_gemm_top (${FAMILY} hierarchical)" "
        read_verilog -sv ${INTEGRATED_TOP_RTL}
        synth_xilinx -family ${FAMILY} -top integrated_gemm_top -noiopad
        tee -o ${BUILD_DIR}/integrated_gemm_top_${FAMILY}_hier_stat.txt stat -top integrated_gemm_top
    "

    # 2. Primary integrated module: integrated_gemm_top (flattened with I/O pads + JSON + post-synth Verilog)
    run_yosys_cmd "${BUILD_DIR}/integrated_gemm_top_${FAMILY}_flat.log" \
        "integrated_gemm_top (${FAMILY} flattened)" "
        read_verilog -sv ${INTEGRATED_TOP_RTL}
        synth_xilinx -family ${FAMILY} -top integrated_gemm_top -flatten
        write_json ${BUILD_DIR}/integrated_gemm_top_${FAMILY}_flat.json
        tee -o ${BUILD_DIR}/integrated_gemm_top_${FAMILY}_flat_stat.txt stat
        write_verilog -noattr ${BUILD_DIR}/integrated_gemm_top_${FAMILY}_synth.v
    "

    # 3. Comparative architectures (flattened)
    local name files
    for entry in \
        "top_module|${TOP_RTL}" \
        "tiled_gemm_top|${TILED_RTL}" \
        "sequential_gemm|${BASELINE_RTL}"; do
        name="${entry%%|*}"
        files="${entry#*|}"
        run_yosys_cmd "${BUILD_DIR}/${name}_${FAMILY}_flat.log" \
            "${name} (${FAMILY} flattened)" "
            read_verilog -sv ${files}
            synth_xilinx -family ${FAMILY} -top ${name} -flatten
            tee -o ${BUILD_DIR}/${name}_${FAMILY}_flat_stat.txt stat
        "
    done

    # 4. Standalone mac_unit DSP48E1 inspection (register configuration verification)
    run_yosys_cmd "${BUILD_DIR}/mac_unit_${FAMILY}.log" \
        "mac_unit (${FAMILY} DSP check)" "
        read_verilog -sv ${MAC_RTL}
        synth_xilinx -family ${FAMILY} -top mac_unit -noiopad
        tee -o ${BUILD_DIR}/mac_unit_dsp_dump.txt dump t:DSP48E1
    "

    # 5. Cross-architecture Lattice ECP5 synthesis validation on integrated_gemm_top
    run_yosys_cmd "${BUILD_DIR}/integrated_gemm_top_ecp5.log" \
        "integrated_gemm_top (ecp5 cross-check)" "
        read_verilog -sv ${INTEGRATED_TOP_RTL}
        synth_ecp5 -top integrated_gemm_top
        tee -o ${BUILD_DIR}/integrated_gemm_top_ecp5_stat.txt stat
    "
}

run_path_analysis() {
    echo "Running Yosys pre-mapping structural longest topological path (ltp -noff)..."
    local name files
    for entry in \
        "integrated_gemm_top|${INTEGRATED_TOP_RTL}" \
        "tiled_gemm_top|${TILED_RTL}" \
        "top_module|${TOP_RTL}" \
        "sequential_gemm|${BASELINE_RTL}"; do
        name="${entry%%|*}"
        files="${entry#*|}"
        run_yosys_cmd "${BUILD_DIR}/${name}_rtl_ltp.txt" \
            "${name} (RTL LTP check)" "
            read_verilog -sv ${files}
            hierarchy -check -top ${name}
            proc
            flatten
            opt
            check -assert
            ltp -noff
        "
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
