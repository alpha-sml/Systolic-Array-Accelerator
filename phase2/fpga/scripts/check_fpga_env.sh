#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-}"
YOSYS_BIN="${YOSYS:-yosys}"
TARGET_PART="${FPGA_TARGET_PART:-UNSPECIFIED}"
BOARD_NAME="${FPGA_BOARD:-UNSPECIFIED}"
CONSTRAINTS_FILE="${FPGA_CONSTRAINTS:-}"

print_tool_inventory() {
    echo "Tool inventory check:"
    for tool in yosys yosys-abc vivado quartus_sh quartus_sta nextpnr-xilinx nextpnr-ecp5 nextpnr-ice40 nextpnr-himbaechel icetime icepack ecppack openFPGALoader sta; do
        if path="$(command -v "$tool" 2>/dev/null)"; then
            echo "  [FOUND]   $tool -> $path"
        else
            echo "  [MISSING] $tool"
        fi
    done
    echo "Target configuration:"
    echo "  FPGA_TARGET_PART : ${TARGET_PART}"
    echo "  FPGA_BOARD       : ${BOARD_NAME}"
    if [ -n "$CONSTRAINTS_FILE" ]; then
        echo "  FPGA_CONSTRAINTS : ${CONSTRAINTS_FILE}"
    else
        echo "  FPGA_CONSTRAINTS : <unspecified>"
    fi
}

case "$MODE" in
    synth)
        if ! command -v "$YOSYS_BIN" >/dev/null 2>&1; then
            echo "ERROR: Yosys ('$YOSYS_BIN') is not installed or not in PATH." >&2
            echo "STATUS: NOT RUN — open-source technology-mapped synthesis cannot proceed." >&2
            exit 1
        fi
        ;;
    timing)
        has_vivado=0
        has_quartus=0
        has_nextpnr=0
        command -v vivado >/dev/null 2>&1 && has_vivado=1 || true
        command -v quartus_sta >/dev/null 2>&1 && has_quartus=1 || true
        if command -v nextpnr-xilinx >/dev/null 2>&1 || command -v nextpnr-ecp5 >/dev/null 2>&1 || { command -v nextpnr-ice40 >/dev/null 2>&1 && command -v icetime >/dev/null 2>&1; }; then
            has_nextpnr=1
        fi

        missing_reason=""
        if [ "$has_vivado" -eq 0 ] && [ "$has_quartus" -eq 0 ] && [ "$has_nextpnr" -eq 0 ]; then
            missing_reason="No vendor STA or FPGA PnR timing tool (Vivado, Quartus STA, or nextpnr) is installed."
        elif [ "$TARGET_PART" = "UNSPECIFIED" ] || [ -z "$TARGET_PART" ]; then
            missing_reason="FPGA_TARGET_PART is UNSPECIFIED; post-implementation timing depends on an actual FPGA part and speed grade."
        elif [ -z "$CONSTRAINTS_FILE" ] || [ ! -f "$CONSTRAINTS_FILE" ]; then
            missing_reason="FPGA_CONSTRAINTS is missing or unreadable ('$CONSTRAINTS_FILE'); valid clock and I/O constraints are required."
        fi

        if [ -n "$missing_reason" ]; then
            echo "==================================================================" >&2
            echo "FPGA STATIC TIMING ANALYSIS (make fpga-timing)" >&2
            echo "STATUS: NOT RUN — real FPGA static timing analysis cannot be performed." >&2
            echo "Reason: $missing_reason" >&2
            echo "" >&2
            print_tool_inventory >&2
            echo "" >&2
            echo "Note: For pre-placement Yosys structural logic-depth inspection," >&2
            echo "      run: make fpga-path-analysis" >&2
            echo "==================================================================" >&2
            exit 1
        fi
        ;;
    bitstream)
        has_vivado=0
        has_quartus=0
        has_oss_pnr=0
        command -v vivado >/dev/null 2>&1 && has_vivado=1 || true
        command -v quartus_sh >/dev/null 2>&1 && has_quartus=1 || true
        if { command -v nextpnr-ecp5 >/dev/null 2>&1 && command -v ecppack >/dev/null 2>&1; } || { command -v nextpnr-ice40 >/dev/null 2>&1 && command -v icepack >/dev/null 2>&1; }; then
            has_oss_pnr=1
        fi

        missing_reason=""
        if [ "$has_vivado" -eq 0 ] && [ "$has_quartus" -eq 0 ] && [ "$has_oss_pnr" -eq 0 ]; then
            missing_reason="No FPGA place-and-route and bitstream generation toolchain (Vivado, Quartus, or nextpnr + packer) is installed."
        elif [ "$TARGET_PART" = "UNSPECIFIED" ] || [ -z "$TARGET_PART" ]; then
            missing_reason="FPGA_TARGET_PART is UNSPECIFIED; device part number is required for implementation and bitstream generation."
        elif [ -z "$CONSTRAINTS_FILE" ] || [ ! -f "$CONSTRAINTS_FILE" ]; then
            missing_reason="FPGA_CONSTRAINTS is missing or unreadable ('$CONSTRAINTS_FILE'); official board pinout/clock constraints are required."
        fi

        if [ -n "$missing_reason" ]; then
            echo "==================================================================" >&2
            echo "FPGA PLACE-AND-ROUTE & BITSTREAM GENERATION (make fpga-bitstream)" >&2
            echo "STATUS: NOT RUN — FPGA place-and-route and bitstream generation cannot be performed." >&2
            echo "Reason: $missing_reason" >&2
            echo "" >&2
            print_tool_inventory >&2
            echo "" >&2
            echo "To execute Vivado batch implementation on a supported host, set:" >&2
            echo "  make fpga-bitstream FPGA_TARGET_PART=<part> FPGA_CONSTRAINTS=<board.xdc>" >&2
            echo "==================================================================" >&2
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {synth|timing|bitstream}" >&2
        exit 2
        ;;
esac
