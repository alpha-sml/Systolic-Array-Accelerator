#!/usr/bin/env python3
"""Parse Yosys technology-mapped synthesis and structural path reports."""

import argparse
from pathlib import Path
import re
import sys
from typing import Dict, List, Optional, Tuple


def parse_cell_counts_from_block(text: str) -> Dict[str, int]:
    """Parse cell type -> count pairs from a Yosys stat block."""
    counts: Dict[str, int] = {}
    in_cells = False
    for line in text.splitlines():
        if re.search(r"^\s+\d+\s+cells\s*$", line) or re.search(r"^\s+-\s+cells\s*$", line):
            in_cells = True
            continue
        if in_cells:
            if re.match(r"^\s*$", line) or "submodules" in line or "Estimated number of LCs" in line or "===" in line:
                if "submodules" in line:
                    # In pre-map stat blocks, CARRY4/FDCE/etc. appear under submodules
                    continue
                if re.match(r"^\s*$", line) or "Estimated number of LCs" in line or "===" in line:
                    in_cells = False
                    continue
            m = re.match(r"^\s+(\d+)\s+(\S+)\s*$", line)
            if m:
                val = int(m.group(1))
                cell = m.group(2)
                counts[cell] = counts.get(cell, 0) + val
    return counts


def parse_flat_stat(stat_path: Path, log_path: Path) -> Dict[str, int]:
    """Parse flattened Xilinx stat output plus Estimated LCs and ABC9 levels from log."""
    if not stat_path.exists():
        raise FileNotFoundError(f"Missing stat file: {stat_path}")
    stat_text = stat_path.read_text(encoding="utf-8", errors="replace")
    # Take the final 'Count including submodules' or local block from stat_path
    m_hier = re.search(r"\+----------Count including submodules\.(.*)", stat_text, re.S)
    block = m_hier.group(1) if m_hier else stat_text
    counts = parse_cell_counts_from_block(block)

    if log_path.exists():
        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        m_lc = re.findall(r"Estimated number of LCs:\s+(\d+)", log_text)
        if m_lc:
            counts["EST_LCS"] = int(m_lc[-1])
        # Extract ABC9 mapping LUT count & levels (take last occurrence)
        m_abc = re.findall(
            r"ABC:\s+Mapping\s+\(K=(\d+)\)\s*:\s+lut\s*=\s*(\d+)\s+edge\s*=\s*(\d+)\s+lev\s*=\s*(\d+)\s+\(([^)]+)\)\s+levB\s*=\s*(\d+)",
            log_text,
        )
        if m_abc:
            k, lut, edge, lev, lev_ns_est, lev_b = m_abc[-1]
            counts["ABC9_K"] = int(k)
            counts["ABC9_LUT"] = int(lut)
            counts["ABC9_LEV"] = int(lev)
            counts["ABC9_LEVB"] = int(lev_b)
        m_warn = re.findall(r"Warnings:\s+(\d+)\s+unique messages,\s+(\d+)\s+total", log_text)
        if m_warn:
            counts["WARN_UNIQUE"] = int(m_warn[-1][0])
            counts["WARN_TOTAL"] = int(m_warn[-1][1])
    return counts


def parse_hier_stat(stat_path: Path) -> Tuple[Dict[str, Dict[str, int]], Dict[str, int]]:
    """Parse per-module local counts and total hierarchy counts from hierarchical stat."""
    if not stat_path.exists():
        raise FileNotFoundError(f"Missing hierarchical stat file: {stat_path}")
    text = stat_path.read_text(encoding="utf-8", errors="replace")
    sections = re.split(r"^=== (.+?) ===\s*$", text, flags=re.M)
    per_module: Dict[str, Dict[str, int]] = {}
    total_hier: Dict[str, int] = {}

    for idx in range(1, len(sections), 2):
        name = sections[idx].strip()
        body = sections[idx + 1]
        if name == "design hierarchy":
            m = re.search(r"\+----------Count including submodules\.(.*)", body, re.S)
            if m:
                total_hier = parse_cell_counts_from_block(m.group(1))
        else:
            # Normalize $paramod$<hash>\mod_name -> mod_name
            clean_name = name.split("\\")[-1] if "\\" in name else name
            per_module[clean_name] = parse_cell_counts_from_block(body)
    return per_module, total_hier


def parse_ecp5_stat(stat_path: Path) -> Dict[str, int]:
    """Parse Lattice ECP5 stat counts."""
    if not stat_path.exists():
        return {}
    text = stat_path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"\+----------Count including submodules\.(.*)", text, re.S)
    block = m.group(1) if m else text
    return parse_cell_counts_from_block(block)


def parse_dsp_origins(log_path: Path) -> List[str]:
    """Extract RTL origin strings for Xilinx DSP packing."""
    if not log_path.exists():
        return []
    text = log_path.read_text(encoding="utf-8", errors="replace")
    return re.findall(r"Analysing\s+(.+?)\s+for Xilinx DSP packing\.", text)


def parse_mac_dsp_params(dump_path: Path) -> Dict[str, str]:
    """Extract DSP48E1 register attributes from mac_unit dump."""
    if not dump_path.exists():
        return {}
    text = dump_path.read_text(encoding="utf-8", errors="replace")
    params: Dict[str, str] = {}
    for key in ("AREG", "BREG", "CREG", "DREG", "ADREG", "MREG", "PREG", "USE_MULT", "USE_SIMD"):
        m = re.search(rf"parameter(?:\s+signed)?\s+\\{key}\s+(\S+)", text)
        if m:
            params[key] = m.group(1).strip('"')
    return params


def parse_rtl_ltp(ltp_path: Path) -> Tuple[Optional[int], List[str]]:
    """Parse pre-mapping Yosys longest topological path output."""
    if not ltp_path.exists():
        return None, []
    text = ltp_path.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"Longest topological path in \S+ \(length=(\d+)\):", text)
    if not m:
        return None, []
    length = int(m.group(1))
    lines: List[str] = []
    after = text[m.end():].splitlines()
    for line in after:
        if re.match(r"^\s*(\d+|ff):", line):
            lines.append(line.rstrip())
        elif lines and not line.strip():
            break
    return length, lines


def sum_luts(counts: Dict[str, int]) -> int:
    """Sum LUT1..LUT6 cells (excluding INV unless counted separately)."""
    return sum(counts.get(f"LUT{i}", 0) for i in range(1, 7))


def sum_ffs(counts: Dict[str, int]) -> int:
    """Sum Xilinx flip-flop primitives."""
    return sum(counts.get(ff, 0) for ff in ("FDCE", "FDPE", "FDRE", "FDSE"))


def sum_brams(counts: Dict[str, int]) -> int:
    """Sum Xilinx block RAM primitives."""
    return counts.get("RAMB18E1", 0) + counts.get("RAMB36E1", 0)


def build_utilization_report(build_dir: Path, family: str) -> str:
    """Build formatted resource utilization report string."""
    env_file = build_dir / "env_info.txt"
    env_info = env_file.read_text(encoding="utf-8", errors="replace").strip() if env_file.exists() else "Unavailable"

    designs = ["phase2_top_module", "tiled_gemm_top", "top_module", "sequential_gemm"]
    flat_stats: Dict[str, Dict[str, int]] = {}
    for d in designs:
        flat_stats[d] = parse_flat_stat(
            build_dir / f"{d}_{family}_flat_stat.txt",
            build_dir / f"{d}_{family}_flat.log",
        )

    hier_modules, hier_total = parse_hier_stat(build_dir / f"phase2_top_module_{family}_hier_stat.txt")
    ecp5_counts = parse_ecp5_stat(build_dir / "phase2_top_module_ecp5_stat.txt")
    dsp_origins = parse_dsp_origins(build_dir / f"phase2_top_module_{family}_flat.log")
    mac_dsp_params = parse_mac_dsp_params(build_dir / "mac_unit_dsp_dump.txt")

    p2 = flat_stats["phase2_top_module"]
    p2_luts = sum_luts(p2)
    p2_ffs = sum_ffs(p2)
    p2_dsp = p2.get("DSP48E1", 0)
    p2_bram = sum_brams(p2)
    p2_carry = p2.get("CARRY4", 0)
    p2_mux = p2.get("MUXF7", 0) + p2.get("MUXF8", 0)
    p2_io = p2.get("IBUF", 0) + p2.get("OBUF", 0)

    out: List[str] = []
    out.append("=" * 88)
    out.append("FPGA RESOURCE UTILIZATION REPORT (YOSYS TECHNOLOGY-MAPPED SYNTHESIS)")
    out.append("=" * 88)
    out.append(env_info)
    out.append("")
    out.append("NOTE: Target FPGA part number and device capacity are UNSPECIFIED in the repository.")
    out.append("      Available resources and Utilization (%) are marked Unavailable rather than")
    out.append("      invented. These counts represent post-synthesis mapped primitives before PnR.")
    out.append("")
    out.append("-" * 88)
    out.append(f"1. PRIMARY TOP MODULE: phase2_top_module (Xilinx {family}, flattened with I/O buffers)")
    out.append("-" * 88)
    out.append(f"{'Resource':<34} | {'Used':>8} | {'Available':<22} | {'Utilization (%)':<16}")
    out.append("-" * 88)

    rows = [
        ("Slice LUTs (LUT1..LUT6)", p2_luts),
        ("  LUT1 / LUT2 / LUT3", f"{p2.get('LUT1',0)}/{p2.get('LUT2',0)}/{p2.get('LUT3',0)}"),
        ("  LUT4 / LUT5 / LUT6", f"{p2.get('LUT4',0)}/{p2.get('LUT5',0)}/{p2.get('LUT6',0)}"),
        ("Estimated Logic Cells (Yosys)", p2.get("EST_LCS", "N/A")),
        ("Flip-Flops / Registers (FDCE+FDPE)", f"{p2_ffs} ({p2.get('FDCE',0)}+{p2.get('FDPE',0)})"),
        ("DSP Blocks (DSP48E1)", p2_dsp),
        ("Block RAM (RAMB18E1 + RAMB36E1)", p2_bram),
        ("Carry Chains (CARRY4)", p2_carry),
        ("Wide Muxes (MUXF7 + MUXF8)", f"{p2_mux} ({p2.get('MUXF7',0)}+{p2.get('MUXF8',0)})"),
        ("Clock Buffers (BUFG)", p2.get("BUFG", 0)),
        ("Inverters (INV)", p2.get("INV", 0)),
        ("Bonded I/O Buffers (IBUF + OBUF)", f"{p2_io} ({p2.get('IBUF',0)}+{p2.get('OBUF',0)})"),
    ]
    unavail = "Unavailable (part unspec)"
    for res_name, used_val in rows:
        out.append(f"{res_name:<34} | {str(used_val):>8} | {unavail:<22} | {unavail:<16}")

    out.append("")
    out.append("-" * 88)
    out.append(f"2. HIERARCHICAL MODULE ATTRIBUTION: phase2_top_module (Xilinx {family}, -noiopad)")
    out.append("-" * 88)
    hier_luts = sum_luts(hier_total)
    hier_ffs = sum_ffs(hier_total)
    hier_dsp = hier_total.get("DSP48E1", 0)
    out.append(f"{'Module':<28} | {'LUTs':>7} | {'LUT %':>6} | {'FFs':>6} | {'DSP48E1':>7} | {'CARRY4':>6} | {'MUXF7/8':>7}")
    out.append("-" * 88)

    # Aggregate 9x processing_element + 9x mac_unit into systolic_array summary too
    ordered_mods = [
        "partial_result_buffer",
        "tiled_input_buffer",
        "burst_matrix_interface",
        "matrix_tiling_controller",
        "systolic_controller",
        "control_fsm",
        "processing_element",
        "mac_unit",
        "pe_interconnect",
        "systolic_array",
        "phase2_top_module",
    ]
    for mod in ordered_mods:
        c = hier_modules.get(mod, {})
        if mod == "processing_element":
            luts = sum_luts(c) * 9
            ffs = sum_ffs(c) * 9
            dsp = c.get("DSP48E1", 0) * 9
            carry = c.get("CARRY4", 0) * 9
            mux = (c.get("MUXF7", 0) + c.get("MUXF8", 0)) * 9
            label = "processing_element (x9)"
        elif mod == "mac_unit":
            luts = sum_luts(c) * 9
            ffs = sum_ffs(c) * 9
            dsp = c.get("DSP48E1", 0) * 9
            carry = c.get("CARRY4", 0) * 9
            mux = (c.get("MUXF7", 0) + c.get("MUXF8", 0)) * 9
            label = "mac_unit (x9)"
        else:
            luts = sum_luts(c)
            ffs = sum_ffs(c)
            dsp = c.get("DSP48E1", 0)
            carry = c.get("CARRY4", 0)
            mux = c.get("MUXF7", 0) + c.get("MUXF8", 0)
            label = mod
        pct = (100.0 * luts / hier_luts) if hier_luts else 0.0
        out.append(f"{label:<28} | {luts:>7} | {pct:>5.1f}% | {ffs:>6} | {dsp:>7} | {carry:>6} | {mux:>7}")

    out.append("-" * 88)
    out.append(
        f"{'TOTAL (hierarchical -noiopad)':<28} | {hier_luts:>7} | {'100.0%':>6} | {hier_ffs:>6} | {hier_dsp:>7} | {hier_total.get('CARRY4',0):>6} | {hier_total.get('MUXF7',0)+hier_total.get('MUXF8',0):>7}"
    )

    out.append("")
    out.append("-" * 88)
    out.append(f"3. ARCHITECTURAL COMPARISON (Xilinx {family}, flattened with I/O pads)")
    out.append("-" * 88)
    out.append(f"{'Top Module':<22} | {'LUTs':>7} | {'Est LCs':>7} | {'FFs':>6} | {'DSP48E1':>7} | {'BRAM':>5} | {'CARRY4':>6} | {'IOs':>5}")
    out.append("-" * 88)
    for d in designs:
        s = flat_stats[d]
        out.append(
            f"{d:<22} | {sum_luts(s):>7} | {str(s.get('EST_LCS','N/A')):>7} | {sum_ffs(s):>6} | "
            f"{s.get('DSP48E1',0):>7} | {sum_brams(s):>5} | {s.get('CARRY4',0):>6} | "
            f"{s.get('IBUF',0)+s.get('OBUF',0):>5}"
        )

    if ecp5_counts:
        out.append("")
        out.append("-" * 88)
        out.append("4. CROSS-ARCHITECTURE CHECK: phase2_top_module (Lattice ECP5, synth_ecp5)")
        out.append("-" * 88)
        out.append(
            f"  LUT4={ecp5_counts.get('LUT4',0)} | TRELLIS_FF={ecp5_counts.get('TRELLIS_FF',0)} | "
            f"MULT18X18D={ecp5_counts.get('MULT18X18D',0)} | DP16KD(BRAM)={ecp5_counts.get('DP16KD',0)} | "
            f"CCU2C={ecp5_counts.get('CCU2C',0)} | PFUMX={ecp5_counts.get('PFUMX',0)} | "
            f"L6MUX21={ecp5_counts.get('L6MUX21',0)}"
        )

    out.append("")
    out.append("-" * 88)
    out.append("5. DSP48E1 ATTRIBUTION & REGISTER CONFIGURATION FINDINGS")
    out.append("-" * 88)
    out.append(f"  Total DSP48E1 inferred in phase2_top_module (flattened): {p2_dsp}")
    out.append(f"  DSP packing origins observed in Yosys log ({len(dsp_origins)} entries):")
    for origin in dsp_origins:
        out.append(f"    - {origin}")
    if mac_dsp_params:
        regs = ", ".join(f"{k}={mac_dsp_params[k]}" for k in ("AREG", "BREG", "CREG", "MREG", "PREG") if k in mac_dsp_params)
        out.append(f"  mac_unit DSP48E1 pipeline registers: {regs} (async rst_n forces external FDCE)")

    return "\n".join(out) + "\n"


def build_timing_and_path_report(build_dir: Path, family: str) -> str:
    """Build timing unavailability and structural path analysis report."""
    env_file = build_dir / "env_info.txt"
    env_info = env_file.read_text(encoding="utf-8", errors="replace").strip() if env_file.exists() else "Unavailable"

    designs = ["phase2_top_module", "tiled_gemm_top", "top_module", "sequential_gemm"]
    out: List[str] = []
    out.append("=" * 88)
    out.append("FPGA TIMING STATUS & STRUCTURAL LOGIC-DEPTH ANALYSIS")
    out.append("=" * 88)
    out.append(env_info)
    out.append("")
    out.append("-" * 88)
    out.append("1. POST-IMPLEMENTATION TIMING METRICS (STATIC TIMING ANALYSIS)")
    out.append("-" * 88)
    out.append("  Status                 : NOT RUN / UNAVAILABLE")
    out.append("  Target clock period    : 10.0 ns (100.0 MHz assumed reference only; NOT a closed FPGA constraint)")
    out.append("  Achieved clock period  : Unavailable (no vendor STA or PnR tool installed)")
    out.append("  Critical path delay    : Unavailable (pre-placement synthesis has no routing/device timing)")
    out.append("  Setup slack            : Unavailable")
    out.append("  Hold slack             : Unavailable")
    out.append("  Maximum frequency Fmax : Unavailable (cannot be computed without valid post-PnR T_critical)")
    out.append("")
    out.append("  Reason: Xilinx Vivado, Intel Quartus, nextpnr, and OpenSTA are not installed, and no")
    out.append("          target FPGA part / speed grade is specified. Yosys ABC9 internal delay weights")
    out.append("          are pre-placement heuristics and are NOT used to claim Fmax or timing closure.")
    out.append("")
    out.append("-" * 88)
    out.append(f"2. STRUCTURAL COMBINATIONAL LOGIC DEPTH (PRE-PLACEMENT, ZERO ROUTING DELAY)")
    out.append("-" * 88)
    out.append(f"{'Top Module':<22} | {'RTL LTP (stages)':>16} | {'ABC9 LUT Depth (lev)':>20} | {'ABC9 Max-Cut (levB)':>19}")
    out.append("-" * 88)

    ltp_details: Dict[str, Tuple[Optional[int], List[str]]] = {}
    for d in designs:
        length, lines = parse_rtl_ltp(build_dir / f"{d}_rtl_ltp.txt")
        ltp_details[d] = (length, lines)
        flat = parse_flat_stat(
            build_dir / f"{d}_{family}_flat_stat.txt",
            build_dir / f"{d}_{family}_flat.log",
        )
        len_str = str(length) if length is not None else "N/A"
        lev_str = str(flat.get("ABC9_LEV", "N/A"))
        levb_str = str(flat.get("ABC9_LEVB", "N/A"))
        out.append(f"{d:<22} | {len_str:>16} | {lev_str:>20} | {levb_str:>19}")

    out.append("")
    out.append("-" * 88)
    out.append("3. LONGEST STRUCTURAL PATH EXCERPTS (Yosys pre-techmap `ltp -noff`)")
    out.append("-" * 88)
    for d in designs:
        length, lines = ltp_details[d]
        out.append(f"\n[{d}] RTL Longest Topological Path (length={length}):")
        if not lines:
            out.append("  (No LTP trace available)")
            continue
        if len(lines) <= 18:
            for ln in lines:
                out.append(f"  {ln}")
        else:
            for ln in lines[:12]:
                out.append(f"  {ln}")
            out.append(f"  ... ({len(lines) - 16} intermediate mux/logic stages omitted) ...")
            for ln in lines[-4:]:
                out.append(f"  {ln}")

    return "\n".join(out) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Parse Yosys FPGA synthesis and path analysis reports.")
    parser.add_argument("--build-dir", default="build/fpga", help="Directory containing Yosys logs and stats")
    parser.add_argument("--family", default="xc7", help="Yosys Xilinx family prefix (default: xc7)")
    parser.add_argument("--print", dest="print_mode", choices=("utilization", "timing", "both", "none"), default="both")
    args = parser.parse_args()

    build_dir = Path(args.build_dir)
    if not build_dir.is_dir():
        print(f"ERROR: Build directory '{build_dir}' does not exist. Run 'make synth-fpga' first.", file=sys.stderr)
        return 1

    util_txt = build_dir / "utilization_summary.txt"
    timing_txt = build_dir / "timing_and_path_analysis.txt"

    util_report = build_utilization_report(build_dir, args.family)
    util_txt.write_text(util_report, encoding="utf-8")

    ltp_ready = (build_dir / "phase2_top_module_rtl_ltp.txt").exists()
    timing_report: Optional[str] = None
    if ltp_ready or args.print_mode in ("timing", "both"):
        timing_report = build_timing_and_path_report(build_dir, args.family)
        timing_txt.write_text(timing_report, encoding="utf-8")

    if args.print_mode == "utilization":
        print(util_report, end="")
    elif args.print_mode == "timing":
        assert timing_report is not None
        print(timing_report, end="")
    elif args.print_mode == "both":
        print(util_report, end="")
        if timing_report is not None:
            print("\n" + timing_report, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
