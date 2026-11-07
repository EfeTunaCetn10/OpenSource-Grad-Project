# TEST-MATRISI — kontrat test kimliği -> commit'li test

Lane P3, dal `lane/p3-testid`, taban `faz5-test` @ 8820c73 üstüne. Bu dosya dokümanlarda geçen her
`T_*` kimliğini (ADR, Roadmap, Abstract, SAGLIK-H1 izlenebilirlik matrisi) bu ağaçta commit'li
bir teste bağlar. Çalıştırma: `python sim/run_tests.py` (`systolic-array-8x8/` içinden); bir test
yalnızca `PASS` yazarsa geçer.

Durum sütunu:

- **KAPSANDI** — kimlik test kaynağında geçiyor ve test regression'da PASS veriyor.
- **İÇERİKLE** — test amacı karşılıyor ama kimlik PASS satırında yok (yalnızca yorumda ya da hiç yok);
  mevcut testlere dokunulmadığı için etiket eklenmedi.
- **KISMİ** — davranışın bir kısmı kapsanıyor, eksik kısım yazılı.
- **KART/ARAÇ** — XSim ile kapanamaz; kart, Vivado raporu ya da dış artefakt gerekir.
- **EKSİK** — XSim'de anlamlı, yazılmadı (gerekçe ile).

## 1. Kontrat kimlikleri

| Kimlik | Kontrat kaynağı | Kapsayan test | PASS satırı / kanıt | Durum |
|---|---|---|---|---|
| `T_NUM_REQ_001` | ADR-003, ADR-014, Roadmap | `tb/tb_requant_unit_num.sv` | `PASS tb_requant_unit_num: N vectors` | KAPSANDI |
| `T_REQ_TIMING_001` | ADR-014, Roadmap | `tb/tb_requant_unit_timing.sv` | `PASS tb_requant_unit_timing` | KAPSANDI |
| `T_REG_PARAM_001` | ADR-015, ADR-017, Roadmap | `tb/tb_axi_lite_regs.sv` | `PASS tb_axi_lite_regs` | KAPSANDI |
| `T_ACCEL_CTRL_001` | LANE-RAPOR-axi (kontrat dışı, tb başlığında) | `tb/tb_accel_top.sv` | `PASS tb_accel_top: 6 bit-exact frames of 784 beats` | KAPSANDI |
| `T_CONV1_E2E_001` | ADR-018 | `tb/tb_conv1_top.sv` (SAGLIK-H1 `tb_accel_top` diyor, kimlik `tb_conv1_top` başlığında) | `PASS tb_conv1_top: 112 tiles, ... bit exact` | İÇERİKLE (kimlik yorumda) |
| `T_CONV2_REPLAY_001` | ADR-018 | `tb/tb_window_gen.sv` (padding sentinel, iki m_ready deseni) | `PASS tb_window_gen` | İÇERİKLE (kimlik yorumda) |
| `T_LAYOUT_ADDR_001` | ADR-018 | `tb/tb_act_buffer.sv` (HWC okuma, 11 katman, kısmi tile, çakışma, swap bütünlüğü); `tb/tb_window_gen.sv` layout sentinel | `PASS: act_buffer HWC read of 11 layers, ...` | İÇERİKLE (kimlik PASS satırında yok; eski rapor satırı `PASS: T_LAYOUT_ADDR_001` değişmiş) |
| `T_ENG_KSTREAM_001` | ADR-018 | `tb/tb_compute_engine.sv` (K=75/150/400) | `PASS tb_compute_engine` | İÇERİKLE (kimlik yorumda) |
| `T_ENG_SKEW_001` | ADR-018 | `tb/tb_compute_engine.sv` | `PASS tb_compute_engine` | İÇERİKLE (kimlik yorumda) |
| `T_ENG_WRAP_001` | çalışma kitabı | `tb/tb_compute_engine.sv` (16384 x 131073 INT32 sınırını geçer) | `PASS tb_compute_engine` | İÇERİKLE (kimlik yorumda) |
| `T_NUM_CONV_001` | Roadmap | `tb/tb_sys_chain.sv` (3x3 pad1 48/24/12/6, 5x5 LeNet, FC flatten; her pass Python zincirine bit-exact); ayrıca `tb_conv1_top`, `tb_lenet_e2e` | `PASS T_NUM_CONV_001: ...` | **KAPSANDI (yeni)** |
| `T_NUM_OVF_001` | ADR-017, Roadmap | `tb/tb_sys_ovf.sv` (acc+bias +-2^31 sınırı, +-1, wrap32 sonra requant, `m_ovf_flat`/`m_sat_flat`, ERROR[2] yalnızca bayrak) | `PASS T_NUM_OVF_001: ...` | **KAPSANDI (yeni)** |
| `T_AXI_BP_001` | ADR-017, Roadmap | `tb/tb_sys_bp.sv` (13 stall profili: LFSR %25/50/75, burst, ilk beat'ten tutma, pool; m_* kararlılık; STALL_IN/OUT sayaçları) | `PASS T_AXI_BP_001: ...` | **KAPSANDI (yeni)** |
| `T_RST_001` | Roadmap | `tb/tb_sys_faults.sv` (R1 act_buffer pass ortasında SOFT_RESET, R2 s_* frame ortasında SOFT_RESET, R3 pass ortasında rst_n; abort/bayrak sonrası SOFT_RESET'siz iyi pass: S7b, S7d, S4, S7c) | `PASS T_RST_001: ...` | **KAPSANDI (yeni)** |
| `T_MEM_PINGPONG_001` | ADR-018 | `tb/tb_sys_chain.sv` (buf_sel yalnızca kabul edilen 9 swap'ta döner, erken swap reddedilir, yazılan katman okunan bankayı bozmaz; çok-tile 2/3/4/15 tile); birim: `tb_act_buffer` | `PASS T_MEM_PINGPONG_001: ...` | **KAPSANDI (yeni)** |
| `T_NET_BITEXACT_001` | delegasyon/2026-10-07 memosu | `tb/tb_lenet_e2e.sv` (7 sınır); `tb/tb_sys_chain.sv` (LeNet ve v3 kuyruğunda her katman çıkışı bank/m_* olarak golden'a karşı) | `PASS tb_lenet_e2e: all 7 boundaries`, `PASS tb_sys_chain: ...` | KISMİ — tam v3 ağı (7 katman, 48x48) P2 hattında (`tb_v3_e2e`), bu ağaçta yok |
| `T_FC1_ORDER_001` | ADR-018 | `tb_sys_chain` S5/S6 fc1 (400 ve 288 giriş, (h,w,c) flatten, rastgele ağırlık); `tb_fc_layer` | `PASS tb_sys_chain: ...` | KISMİ — sıra yanlışsa çıktı bozulur (davranışsal), ama tek-hot ağırlık/aktivasyon testi yazılmadı |
| `T_AXI_LANE_001` | ADR-016, ADR-017, Roadmap | `tb_sys_chain` rastgele baytlı s_* frame'leri bit-exact (bayt lane permütasyonu çıktıyı bozar) | — | KISMİ — koordinat kodlu "bilinen desen" testi yok; AXIS/DMA'ya özgü kısım (`axi4stream_vip`, TKEEP, 64-bit genişlik) KART/ARAÇ |
| `T_AXI_ROW_001` | delegasyon/2026-10-07 memosu | — | — | KART/ARAÇ — "final TKEEP" için TKEEP portu RTL'de yok (SAGLIK-H1-06); satır geçişi s_* frame'lerinde dolaylı kapsanıyor |
| `T_STA_001` | Roadmap | yok | `vivado/check_impl` çıktıları (OOC route, P1 hattı) | KART/ARAÇ — post-route STA Vivado'dur, XSim değil; entegre BD için kart öncesi yapılacak |
| `T_CDC_001` | Roadmap | yok | — | KART/ARAÇ — tek clock; `report_cdc` Vivado raporu, PS7 block design kurulunca anlamlı |
| `T_ML_ACC_001` | Roadmap | yok | — | KART/ARAÇ — Kişi A artefaktları (R1) ve tüm test seti gerekir; RTL bit-exact + Python INT8 accuracy argümanı DURUM-RAPORU §4'te |

## 2. Kimlik gibi görünen ama kontrat olmayan etiketler

- Test içi yerel etiketler (kontrat değil): `T_ENG_CONFIG/DRAIN/SOURCE/START` (`tb_compute_engine`),
  `T_LC_*` (`tb_layer_ctrl`), `T_REQA_*` (`tb_requant_array`).
- Regex yanlış eşleşmeleri: `T_H_MAX`, `T_W_MAX` (`OUT_H_MAX` içinde), `T_WAIT_TILE` (`ST_WAIT_TILE`),
  `T_PATH_CHECK` (`WEIGHT_PATH_CHECK`), `T_VIVADO_DIRS`.

## 3. Smoke -> kalıcı test eşlemesi (R6)

`smoke/` aynen duruyor (`bash smoke/run_smoke.sh`). Aynı senaryolar artık regression'da.

| Smoke | Kalıcı test | Not |
|---|---|---|
| S1, S2, S3 | `tb_sys_chain` | S1'e `T_MEM_PINGPONG_001` denetimleri eklendi (erken swap reddi, okunan bank bütünlüğü, buf_sel izleyicisi) |
| S5, S6 | `tb_sys_chain` | bank karşılaştırmaları aynı, `sys_s5_*`/`sys_s6_*` vektörleri |
| S4 | `tb_sys_faults` | S6 vektörleriyle, saklanan conv4 katmanından iyi pass |
| S7a, S7b, S7c | `tb_sys_faults` | aynı beklentiler (ERROR 80/detail 1000, 10/2000, 40/8000) |
| — | `tb_sys_faults` S7d | yeni: TLAST geç (ERROR[5]/detail[14], pass biter, fazla beat reddedilir) |
| — | `tb_sys_faults` R1/R2/R3 | yeni: `T_RST_001` |
| — | `tb_sys_bp`, `tb_sys_ovf` | yeni: `T_AXI_BP_001`, `T_NUM_OVF_001` |

Vektörler `model/gen_sys_vectors.py` ile üretilir (`sim/vectors/sys_*.mem`, gitignore'lu); golden saf
Python, RTL'den okunmaz.
