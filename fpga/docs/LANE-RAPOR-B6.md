# Lane B6 fix-round report

Date: 2026-11-14  
Worktree: `C:\grad-wt\b6` (`lane/b6-bd`)  
Tool: Vivado/XSim 2025.1, `XILINX_LOCAL_USER_DATA=no`

## Files

- `systolic-array-8x8/k3/tb_k3_prog.sv`: removed the HP0-to-PS7-memory mirror and the unjoined `wait_mem_update`; comparisons now use a passive HP0 write capture with an AW FIFO, AWLEN/WLAST checking, WSTRB byte merging, and FIXED/INCR burst addressing.
- `systolic-array-8x8/vivado/build_bd.tcl`: replaced both invalid Tcl `!~` expressions with `![string match "*Complete*" ...]`.
- `LANE-RAPOR-B6.md`: this report.
- `systolic-array-8x8/k3/run_k3.py` and `run_k3_sim.tcl` were exercised but not changed in this fix round.

## Block design and address map

The BD contains PS7 (PYNQ-Z2 board preset), AXI DMA in simple mode, the `accel_axis_wrapper` module reference, separate 1-to-2 GP0 control and 2-to-1 HP0 memory AXI interconnects, `proc_sys_reset`, reset inverter, constant-one lock input, and a three-input IRQ concatenator. FCLK0 is 100 MHz and clocks every PL AXI/AXIS endpoint. DMA MM2S streams into the accelerator; accelerator output streams into DMA S2MM. DMA MM2S and S2MM memory masters share PS7 HP0. IRQ order is MM2S, S2MM, accelerator.

Address map:

| Master/address space | Slave segment | Base | Range |
|---|---|---:|---:|
| PS7 GP0 `Data` | AXI DMA registers | `0x4040_0000` | 64 KiB |
| PS7 GP0 `Data` | accelerator registers | `0x43C0_0000` | 64 KiB |
| DMA MM2S/S2MM | PS7 HP0 DDR/low OCM | `0x0000_0000` | 512 MiB |

Testbench source and destination buffers are `0x1000_0000` and `0x1100_0000`.

## `validate_bd_design` warnings

- `PSU-1..4` critical warnings: the installed PYNQ-Z2 preset supplies negative DDR DQS-to-clock delays (`-0.051`, `-0.006`, `-0.009`, `-0.033`). These are board-preset/electrical warnings, not PL connectivity errors.
- `BD 41-2384`: AXI ID-width adaptation between the one-bit interconnect IDs and six-bit PS7 HP0 IDs (BID, RID, WID, ARID, AWID); lower bits are connected. The DMA uses ID 1 and the observed transfers/responses are clean.
- Generation-time advisory classes also include `BD 5-1043` (utility IP migration to inline HDL), `IP_Flow 19-4994` (regenerated constraint overwrite), and `IP_Flow 19-5611` (default reset association for PS7 interfaces). No validation error was emitted.

## PS7 VIP finding and fix

The cause is the testbench/VIP interaction, not the DMA data path. In the original code, the HP0 monitor called `PS7.write_mem` at W handshake. That artificial sparse-memory write immediately satisfied the forked `wait_mem_update`, even though the VIP's own HP0-to-DDR commit is independently queued. The orchestrator log shows the false match at each W (`0x5`, then `0x49fa1d1c`, then `0x1433`) while subsequent `read_mem` returned exactly the preceding transfer.

A short direct-model diagnostic removed the mirror but retained real-DDR waiting: HP0 accepted `0000000000000005` with `WSTRB=ff`, DMA completed with `DMASR=00001002` and 8/8 bytes, but no PS7 DDR update event occurred within 100 us and `read_mem` was still `X`. Therefore the Vivado 2025.1 PS7 VIP DDR model is not a usable completion oracle for this HP0 path.

The permanent fix does not write PS7 memory and does not use `wait_mem_update` or a guessed delay. It passively captures accepted HP0 writes. AW descriptors are queued; WLAST is checked against AWLEN; enabled WSTRB lanes alone update the capture; FIXED addresses remain fixed and INCR addresses advance by `1 << AWSIZE`; unsupported burst types fail explicitly. DMA status and transferred-length checks remain independent.

## Real run output

LeNet baseline (`python k3/run_k3.py --program lenet`):

```text
K3_HP_WRITE: W data=0f1278b0c67f8a48 strb=ff last=1 id=1
K3_S2MM_BYTES: offset=0 expected=8 received=8 status=00001002
K3_HP_WRITE: W data=000000000000be27 strb=ff last=1 id=1
K3_S2MM_BYTES: offset=1 expected=8 received=8 status=00001002
PASS tb_k3_prog: images=1 passes=31 beats compared=3 predicted classes=2
K3_RUN: mutation=none wall_seconds=1729.552 simulated_time=13895655 ns
```

The three compared beats include the permanent one-beat bring-up plus two one-beat logits writes.

Full v3 (`python k3/run_k3.py --program v3`), run once:

```text
K3_HP_WRITE: W data=ce19110649fa1d1c strb=ff last=1 id=1
K3_S2MM_BYTES: offset=0 expected=8 received=8 status=00001002
K3_HP_WRITE: W data=0000000000001433 strb=ff last=1 id=1
K3_S2MM_BYTES: offset=1 expected=8 received=8 status=00001002
PASS tb_k3_prog: images=1 passes=27 beats compared=3 predicted classes=3
K3_RUN: mutation=none wall_seconds=2734.885 simulated_time=20443385 ns
```

## Mutation results

| Program | Mutation | Expected acceptance | Observed |
|---|---|---|---|
| LeNet | length | must be rejected by byte-count contract | Rejected: each transfer reported `received=8 expected=16`; `FAIL tb_k3_prog: errors=3`; wall 1684.107 s, simulated 13,895,655 ns. |
| LeNet | TLAST held low | must fail by timeout/hang or DMA error | pending |

## `.gitignore` additions needed

The generated projects/vectors are not covered by the current `systolic-array-8x8/.gitignore`. Add:

```gitignore
k3/build/
vivado/build/
```

These lines were not added because this lane is restricted to `k3/` and `vivado/build_bd.tcl` edits.

## Not run

- Implementation/bitstream mode was deliberately not run; the orchestrator owns `impl`.
- Hardware-on-board execution was not run.
