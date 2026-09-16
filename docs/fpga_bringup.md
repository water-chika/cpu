# FPGA bring-up plan

**Status: PLAN ONLY.** Nothing in this document has been run on hardware. No
Vivado is installed on the machine this was written on (there is no
`/opt/Xilinx` and no `/tools/Xilinx`), so every statement about synthesis,
resources and timing below comes from *reading the RTL*, not from running a
tool. Where a number would have to come from a tool, this document says so
instead of guessing one.

Sections are filled in over several commits; the skeleton lands first.

- [ ] 1. What we are bringing up
- [ ] 2. Phase 0 - everything provable at the desk
- [ ] 3. The short list that genuinely needs hardware
- [ ] 4. On-board phase, in order
- [ ] 5. Troubleshooting
- [ ] 6. Legend: verified locally vs untested
