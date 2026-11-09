# Systolic Array Matrix Multiplication Accelerator

## Description

A Verilog HDL project for a systolic array matrix multiplication accelerator.

## Technology

Verilog HDL

## Project Objective

Prepare a modular RTL design for matrix multiplication using a systolic array architecture.

## Phase I Overview

Phase I is organized into five independent development packages.

## Repository Directory Structure

```text
Phase_1/
├── MAC_PE/
│   └── rtl/
│       ├── mac_unit.v
│       └── processing_element.v
├── Array_Core/
│   └── rtl/
│       ├── pe_interconnect.v
│       └── systolic_array.v
├── Controller/
│   └── rtl/
│       ├── control_fsm.v
│       └── systolic_controller.v
├── Data_Management/
│   └── rtl/
│       ├── input_buffer.v
│       ├── output_buffer.v
│       └── matrix_interface.v
└── Integration/
    ├── rtl/
    │   └── top_module.v
    └── testbench/
        └── tb_top_module.v
```

## Development Status

Repository setup completed. RTL implementation pending.
