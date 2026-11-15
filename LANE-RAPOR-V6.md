# Lane V6 — PS7 VIP DDR readback experiment

Date: 2026-11-15  
Worktree: `C:\grad-wt\v6`  
Tool: Vivado/XSim 2025.1, `XILINX_LOCAL_USER_DATA=no`

## Result

The hypothesis is confirmed, but the mechanism is more specific than a slow commit: the Vivado 2025.1 Zynq-7000 PS7 VIP presents each HP0 write response normally while its internal DDR request consumes the previous transaction's address, data, byte count, and strobes. The first request therefore writes unknowns; transaction N makes transaction N-1 visible. Waiting longer cannot make transaction N appear. A later write is required to displace it.

This is a PS7 VIP internal zero-delay scheduling defect, not a missing AXI B handshake, an API argument-order error, a second memory instance, or a latency-profile choice.

No DDR readback assertion was added to the production K3 program path. Making it pass would require a fake/mirror write, manually invoking an internal commit, or issuing an extra sacrificial HP0 write solely to flush the VIP. None is an honest observation of the completed S2MM transfer. The existing passive HP0 capture remains the result oracle, unchanged in strength.

## VIP source evidence

Installed sources are under:

`C:\Vivado\2025.1\Vivado\data\ip\xilinx\processing_system7_vip_v1_0\hdl`

- `processing_system7_vip_v1_0_23_apis.v:318-321` defines the public API as `read_mem(start_addr, no_of_bytes, data)`. Lines 325-337 decode the address and call `ddrc.ddr.read_mem`, so the experiment used the correct order and reads the same sparse instance written by the DDR controller.
- `processing_system7_vip_v1_0_23_apis.v:786-810` shows `set_slave_profile` only dispatches to `set_latency_type`; HP0 is at line 794. It does not alter the internal DDR write path.
- `processing_system7_vip_v1_0_vl_rfs.sv:10967-11006` places the completed AXI write in the AFI write FIFO.
- `processing_system7_vip_v1_0_vl_rfs.sv:11144-11171` dequeues that FIFO on `posedge SW_CLK`, assigns `WR_DATA`, `WR_ADDR`, `WR_BYTES`, and `WR_DATA_STRB`, then asserts `WR_DATA_VALID_DDR`.
- The four-port DDR arbiter also runs on `posedge sw_clk` (`processing_system7_vip_v1_0_vl_rfs.sv:426`). For arbiter input 2 (DDRC port 1, which carries this HP path) it sets `prt_req = 1` at line 459, then executes `#0 prt_data = prt_data2` and `#0 prt_strb = prt_strb2` at lines 461-462; the current address and byte count are not assigned until lines 467-468. The first `#0` suspends this process into the inactive region after the request is already asserted.
- The DDR controller is another `posedge sw_clk` process (`processing_system7_vip_v1_0_vl_rfs.sv:5207`). When it sees `wr_req`, line 5221 immediately calls `ddr.write_mem(wr_data, wr_addr, wr_bytes, wr_strb)`. It therefore consumes the prior arbiter payload before the `#0` continuation installs the current payload, then acknowledges it at lines 5223-5224.
- The sparse-memory task is `processing_system7_vip_v1_0_vl_rfs.sv:2225-2364`; its read task is at lines 2432-2485. The public `wait_mem_update` path only arms a future sparse write event (`processing_system7_vip_v1_0_vl_rfs.sv:1922-1931`), so it cannot repair or retrospectively observe the current transaction when the arbiter has already submitted stale fields.

## Simulation evidence

`--program bringup` ran five real accelerator/DMA one-beat round trips: values `11`, `22`, and `33` to `0x11000000`, then `44` to `0x11000008`, and `55` to `0x11000010`. The testbench never wrote any destination-region byte.

The decisive final-run lines were:

```text
K3_VIP_HP_FIFO: time=23426 ns addr=11000000 bytes=x data=0000000000000011 strb=ff
K3_VIP_DDR_REQ: time=23427 ns addr=xxxxxxxx bytes=x data=xxxxxxxxxxxxxxxx strb=xx
K3_VIP_SPARSE_POST_ACK: time=23428 ns d0=xxxxxxxxxxxxxxxx d8=xxxxxxxxxxxxxxxx d10=xxxxxxxxxxxxxxxx
K3_HP_WRITE: B time=23815 ns resp=0 id=1
K3_DDR_READ: trial=0 time=24175 ns addr=11000000 data=xxxxxxxxxxxxxxxx expected=0000000000000011

K3_VIP_HP_FIFO: time=47166 ns addr=11000000 bytes=8 data=0000000000000022 strb=ff
K3_VIP_DDR_REQ: time=47167 ns addr=11000000 bytes=8 data=0000000000000011 strb=ff
K3_VIP_SPARSE_POST_ACK: time=47168 ns d0=0000000000000011 d8=xxxxxxxxxxxxxxxx d10=xxxxxxxxxxxxxxxx
K3_HP_WRITE: B time=47555 ns resp=0 id=1
K3_DDR_READ: trial=1 time=47835 ns addr=11000000 data=0000000000000011 expected=0000000000000022

K3_VIP_HP_FIFO: time=70696 ns addr=11000000 bytes=8 data=0000000000000033 strb=ff
K3_VIP_DDR_REQ: time=70697 ns addr=11000000 bytes=8 data=0000000000000022 strb=ff
K3_VIP_SPARSE_POST_ACK: time=70698 ns d0=0000000000000022 d8=xxxxxxxxxxxxxxxx d10=xxxxxxxxxxxxxxxx

K3_VIP_HP_FIFO: time=93076 ns addr=11000008 bytes=8 data=0000000000000044 strb=ff
K3_VIP_DDR_REQ: time=93077 ns addr=11000000 bytes=8 data=0000000000000033 strb=ff
K3_VIP_SPARSE_POST_ACK: time=93078 ns d0=0000000000000033 d8=xxxxxxxxxxxxxxxx d10=xxxxxxxxxxxxxxxx
K3_DDR_READ: trial=3 time=93825 ns addr=11000008 data=xxxxxxxxxxxxxxxx expected=0000000000000044

K3_VIP_HP_FIFO: time=116146 ns addr=11000010 bytes=8 data=0000000000000055 strb=ff
K3_VIP_DDR_REQ: time=116147 ns addr=11000008 bytes=8 data=0000000000000044 strb=ff
K3_VIP_SPARSE_POST_ACK: time=116148 ns d0=0000000000000033 d8=0000000000000044 d10=xxxxxxxxxxxxxxxx
K3_HP_WRITE: B time=116535 ns resp=0 id=1
K3_DDR_READ: trial=4 time=116855 ns addr=11000010 data=xxxxxxxxxxxxxxxx expected=0000000000000055
```

This proves all of the following:

1. HP0/AFI has the current word before the DDR request.
2. The next internal DDR request carries the previous word and previous address.
3. The hierarchical `ddrc.ddr.read_mem` immediately after the VIP's own ack observes that stale write in the sparse memory.
4. The public `read_mem` later returns the same stale data; it is not reading another memory instance.
5. Every transfer still receives an AXI OKAY B response. Missing BREADY/BVALID is not the cause.
6. Moving the destination address moves the previous transaction to its previous address, excluding an address-size argument error.

## Changes

- `systolic-array-8x8/k3/run_k3.py`
  - Added `--program bringup`.
  - Bring-up mode skips neural-network vector generation and vector-file copying.
  - Passes the selected program to the simulation-script generator.
- `systolic-array-8x8/k3/run_k3_sim.tcl`
  - Accepts the program selector and adds `+K3_BRINGUP_ONLY` only for bring-up simulations.
- `systolic-array-8x8/k3/tb_k3_prog.sv`
  - Parameterized the existing one-beat round trip by trial, destination, and data.
  - Added five bring-up-only real DMA/accelerator transfers covering repeated and distinct addresses.
  - Added bring-up-only external B, HP FIFO, DDR request, sparse-memory post-ack, and public-read prints.
  - Kept the passive HP0 capture, byte-count check, DMA status/IOC checks, WLAST/AWLEN checking, WSTRB merge, and expected-data comparisons.
  - Added no testbench destination write and no DDR mirror.

No files under `rtl/`, `tb/`, `model/`, `sim/`, or `vivado/build_bd.tcl` were edited.

## Final runs

Fast experiment:

```text
PASS tb_k3_prog: bringup transfers=5 beats compared=5
K3_RUN: mutation=none wall_seconds=185.318 simulated_time=117125 ns : File "C:/grad-wt/v6/systolic-array-8x8/k3/tb_k3_prog.sv" Line 505
```

The single LeNet run, started only after that bring-up pass:

```text
K3_HP_WRITE: W data=0f1278b0c67f8a48 strb=ff last=1 id=1
K3_S2MM_BYTES: offset=0 expected=8 received=8 status=00001002
K3_HP_WRITE: W data=000000000000be27 strb=ff last=1 id=1
K3_S2MM_BYTES: offset=1 expected=8 received=8 status=00001002
PASS tb_k3_prog: images=1 passes=31 beats compared=3 predicted classes=2
K3_RUN: mutation=none wall_seconds=1986.374 simulated_time=13854915 ns : File "C:/grad-wt/v6/systolic-array-8x8/k3/tb_k3_prog.sv" Line 505
```

## Not run

- The v3 program was not run.
- Length/TLAST mutations were not run.
- Synthesis, implementation, bitstream generation, and hardware execution were not run.
- LeNet was not rerun; exactly one LeNet invocation was made.
