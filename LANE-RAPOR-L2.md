# Lane L2 report — ERR_DETAIL, STATUS.ABORTED, regmap v4

## Files
- `systolic-array-8x8/rtl/axi_lite_regs.sv`
- `systolic-array-8x8/tb/tb_axi_lite_regs.sv`
- `LANE-RAPOR-L2.md`

## Decisions
- `A_ERR_DETAIL` @ 0x024, 16-bit sticky `err_detail_latched`, ORed from new input `err_detail_set` every cycle. W1C is per byte lane (strb[0] -> [7:0], strb[1] -> [15:8]); strb[3:2] and data[31:16] are ignored; reads return 0 above bit 15.
- Same update form as ERROR: `(latched & ~clear) | set`, so hardware set wins over a same-cycle W1C.
- SOFT_RESET clears all detail bits through the registered `soft_reset` pulse (one cycle after the CONTROL write); a same-cycle `err_detail_set` still wins. ERROR is not cleared by SOFT_RESET (unchanged).
- STATUS[5] ABORTED (`aborted_latched`): set by `pass_aborted`; cleared by W1C of DONE (STATUS[2]) or by an accepted START (the branch that emits `start`); a rejected START does not clear it. Hardware set wins over the DONE W1C and over the START clear.
- `REGMAP_VERSION` 16'h0004 (VERSION reads 0x0001_0004). Header map updated (v4, ERR_DETAIL row, ABORTED, explanatory paragraph).
- New inputs have no default values. AXI timing and all other behaviour unchanged. The old tb "unmapped read" probe at 0x024 moved to 0x028.

## Regression
`python sim/run_tests.py` (from systolic-array-8x8/), final line verbatim:
```
16/16 passed
```
With `err_detail_set` and `pass_aborted` unconnected (z) in accel_top, tb_accel_top still passes: it never reads STATUS[5] or 0x024 in a way that depends on them. X/Z does leak into the real hardware state: `err_detail_latched` and `aborted_latched` go X in that tb (STATUS bit 5 reads X). Not checked by tb_accel_top, so no failure; L3 wiring removes it.

## Mutations (both run, restored afterwards)
1. ERR_DETAIL W1C wins over hardware set (`(latched | set) & ~clear`): tb_axi_lite_regs `FAIL ... ERR_DETAIL set-and-clear race mismatch`, 0/1. (My first version of that check passed this mutation because the event stayed asserted after the write; it now drops the event right after the write-complete edge, using a hierarchical `dut.write_complete` wait.)
2. START no longer clears ABORTED: `FAIL ... START did not clear ABORTED`, 0/1.
Clean RTL: 1/1 passed.

## Open questions
- SOFT_RESET does not clear ABORTED (contract lists only DONE W1C / next START). A stale ABORTED survives a SOFT_RESET until the next START; say if SOFT_RESET should clear it.
- SOFT_RESET clearing of ERR_DETAIL happens on the registered pulse, so detail bits raised by L3 during the reset window itself are kept (hardware wins); L3 should not raise detail bits from the reset teardown.
