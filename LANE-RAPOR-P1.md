# LANE-RAPOR-P1 — R3 timing (window_gen handshake -> PE CE)

Branch `lane/p1-timing`, base 8820c73. Changed file: `systolic-array-8x8/rtl/window_gen.sv` only
(no interface change; line_buffer.sv and conv1_top.sv untouched).

## Baseline path (unmodified tree, Default directives)
`IMPL_WNS: 0.344` / `IMPL_WHS: 0.097`.
1. `u_conv1/u_window/out_base_row_reg[1]` -> `u_conv1/u_engine/u_array/g_row[0].g_col[0].u_pe/acc_reg_reg/CEB2`,
   +0.344 ns, 8 levels (CARRY4, LUT3, 6xLUT6), 9.058 ns, 77.7% route.
2. same source -> `src_rem_reg[*]/CE` (accel_top), +0.567 ns, 9 levels.
All top-20 setup paths started at `out_base_row_reg`.

Finding (differs from the brief's hypothesis): win_valid is already a flop decode. The CEB2 path
exists because Vivado absorbed `gather_reg` (= w_data, PE row 0's B input) into the DSP B register,
so CEB2 = gather_reg's clock enable. That enable contained the redundant `gather_reg <= '0` clears
under `rows_ready` (ST_INPUT) and under `m_ready` (ST_OUTPUT). Path 2 is rows_ready -> allow_input
-> line_buffer s_ready -> accel_top source gating.

## Changes
1. Removed the four `gather_reg <= '0` clears in ST_INPUT/ST_OUTPUT. Every ST_READ pass writes all
   eight lanes (padding/inactive lanes as zero) before ST_OUTPUT, so m_data while m_valid is
   unchanged. Reset and restart clears kept (a_restart_rewinds_everything still holds).
   gather_reg's enable is now ST_READ && capture_pending (+ sync reset/restart).
2. Registered row target: `rows_target_q` / `rows_ok_q` are computed from out_base_row's NEXT value
   (`next_base_row` mirrors every assignment: idle tracking, restart, row advance), so they always
   describe the current out_base_row. rows_ready becomes
   `!cfg_error && !lb_write_busy && rows_ok_q && (rows_written >= rows_target_q)` — one unsigned
   compare of two flops instead of add + two signed compares + mux. `>= in_h` replaces `== in_h`
   (rows_written never exceeds in_h). `rows_ok_q` is held low until one cycle after
   frame_started (via frame_started_q) so stage-2 geometry (kh_offset, in_h_coord) has settled.
   Not a lagged ready: allow_input/resume_write stay exact, so no ring-overwrite window opens.
   Latency: +1 cycle only at frame start (before the first window can be ready); none per row.
   Orphaned `bottom_row` / `rows_written_coord` removed.

## Results
- Regression: `16/16 passed`
- Smoke: `SMOKE PASS: errors=0 FRAME_COUNT=71 act_buffer swaps=10`
- Synth: `ACCEL_SYNTH: WNS=1.593 ns LUT=8714 FF=6515 BRAM=48 DSP=88` / `PASS: accel_top synthesis margin`
- Impl Default:  `IMPL_WNS: 0.899` `IMPL_WHS: 0.016`
- Impl Explore (place/phys_opt/route -directive Explore): `IMPL_WNS: 0.899` `IMPL_WHS: 0.016`
- New worst path (both runs): `dp_rst_n_reg` -> `u_conv1/u_requant/g_lane[7].u_req/s3_raw_reg[51]/R`,
  1 level (LUT1), 92.5% route. All top-20 setup paths now start at `dp_rst_n_reg`; no
  `u_window` source in the top 20 (20th: +1.011 ns). Old path gone from top 5 in both runs.
- WHS min path: line_buffer write_group -> distributed RAM WADR, +0.016 ns (hold, met).

## Mutation
`rows_target_q <= ROW_W'(next_bottom_row)` (dropped `+1`: window ready one row early) ->
`tb_window_gen FAIL` (assertion failures), `tb_conv1_top FAIL`; 0/2 passed. Restored.

## Open questions
- Post-route WNS +0.899 ns: above the +0.6 minimum, below the +1.0 target. The limiter is now the
  datapath reset fan-out (`dp_rst_n` -> requant s3_raw sync reset), in accel_top/requant_unit, not
  in P1's files. Options for the orchestrator: replicate dp_rst_n (max_fanout / per-block reset
  flop) or drop the reset from requant data-pipeline registers.
- Default and Explore landed on identical numbers; the result is dominated by the reset net, so
  this shows the old handshake path is no longer the limiter, not a broad placement-variance study.
- Impl script: `scratch/impl/check_impl_accel.tcl` (IMPL_TAG / IMPL_DIR env vars), reports in
  `scratch/impl/rpt_{base_def,new_def,new_exp}/` (not committed).
