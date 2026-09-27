# 8×8 Output-Stationary Systolic Array RTL

Bu paket, PYNQ-Z2 / XC7Z020 hedefi için temiz-kaynak yazılmış, 64 PE'li parametrik bir
SystemVerilog tasarımıdır. Varsayılan sayısal kontrat signed INT8 aktivasyon, signed INT8
ağırlık ve signed INT32 wrapping accumulator'dır. Requantizer'ın product + rounding
offset + arithmetic shift yolu signed 64-bit; INT8 saturation yalnız output'tadır.

Araç sürümü: **Vivado 2025.1** ([[ADR-001 Board ve Araç Sürümü|ADR-001]]), part
`xc7z020clg400-1`.

## İçerik

### RTL — sentez top'una bağlı

- `rtl/pe_os.sv`: Yerel accumulator, A/B forwarding register'ları ve ayrı valid yolları olan PE.
- `rtl/systolic_array_os.sv`: Parametrik `ROWS×COLS` PE ağı; varsayılan 8×8.
- `rtl/compute_engine.sv`: K-streaming kontrolcüsü — row/column skew, clear/feed/flush/drain
  durum makinesi, partial-tile maskesi ve `valid/ready` akış kontrolü. `K_MAX=1024`, yani
  K tavanı yok; harici tile-accumulation gerekmiyor
  ([[ADR-018 K-Streaming ve Ara Aktivasyon Düzeni|ADR-018]]).
- `rtl/systolic_array_8x8.sv`: 64 PE'li sabit isimli Vivado synthesis top'u;
  `compute_engine`'i 8×8 / `K_MAX=1024` ile sarar.

### RTL — henüz top'a bağlanmadı

Aşağıdaki dört modül birim testleriyle doğrulanmış durumda ama **hiçbir yerden instantiate
edilmiyor**: datapath entegrasyonu ve AXI sarmalayıcı henüz yazılmadı. `filelist.f` ve
`vivado/check_synth.tcl` bu yüzden onları kapsamıyor — yani sentezden ve STA'dan hiç
geçmediler. [[ADR-014 Requantizer Port ve Zamanlama Sözleşmesi|ADR-014]]'ün `LAT` değeri de
bu nedenle hâlâ ölçülmüş değil.

- `rtl/line_buffer.sv`: Sekiz bankalı, banka başına tek okuma portlu satır tamponu.
- `rtl/window_gen.sv`: Parametrik valid-convolution pencere üreticisi
  (`K_H`, `K_W`, `C_IN`, `IN_W`, `IN_H`, `STRIDE`, `PAD`). Çıkış sırası output-row →
  sekiz kolonluk tile → `k = ci*(K_H*K_W) + kh*K_W + kw`; her beat aynı `k`'deki sekiz
  pozisyonu taşır ve `compute_engine`'in B-top aktivasyon kenarına birebir oturur.
- `rtl/requant_unit.sv`: ADR-003 / ADR-014 INT32→INT8 requantizer'ı — skid buffer, sabit
  `LAT`, `k_last` kapısı, `out_y_raw` / `out_sat` / `out_ovf`.
- `rtl/axi_lite_regs.sv`: [[ADR-015 Register Map ve Parametre Yükleme|ADR-015]] AXI4-Lite
  register file'ı — shadow + commit protokolü, `ERR_CFG_M0`, W1C bitleri.

### Testbench'ler

Hepsi self-checking. `sim/run_tests.py` `tb_` ile başlayan her modülü kendisi bulur.

- `tb/tb_pe_os.sv`: PE signed-boundary, stall, bubble, clear ve flush testleri.
- `tb/tb_compute_engine.sv`: K-streaming motoru, `model/engine_ref.py`'ye karşı.
- `tb/tb_window_gen.sv`: Pencere akışı, `model/window_ref.py`'ye karşı.
- `tb/tb_requant_unit_num.sv`: `T_NUM_REQ_001` — `$readmemh` vektörleriyle bit-exact sayısal
  kontrol; `pre-clamp y_raw` dahil.
- `tb/tb_requant_unit_timing.sv`: ADR-014 zamanlama sözleşmesi — sabit `LAT`, skid buffer
  backpressure, `k_last` kapısı.
- `tb/tb_axi_lite_regs.sv`: ADR-015 shadow/commit, hata bitleri ve W1C davranışı.

### Golden model ve araçlar

- `model/verify_architecture.py`: Bağımsız cycle model ve golden matrix multiplication kontrolü.
- `model/engine_ref.py`: K-streaming motorunun stdlib-only golden modeli.
- `model/window_ref.py`: HWC aktivasyon pencere akışının golden modeli.
- `model/requant_ref.py`: ADR-003 requantization golden modeli; `python model/requant_ref.py`
  kendi kendini doğrulayan bir kontrol de çalıştırır.
- `model/gen_requant_vectors.py`: `T_NUM_REQ_001` için `$readmemh` vektörlerini üretir.
  Vektörler deterministik ve ~4 MB olduğu için commit edilmiyor; `run_tests.py` eksikse
  kendisi üretir.
- `vivado/create_project.tcl`: Vivado GUI projesini kurar veya yeniden açar.
- `vivado/check_synth.tcl`: XC7Z020 out-of-context synthesis kapısı.
- `tasarim-ve-repo-incelemesi.md`: Kararlar, repo karşılaştırması ve blok diyagramları.
- `block-design-clock-reset-rehberi.md`: IP Integrator'da clock/reset bağlama rehberi.

## Arabirim özeti

`systolic_array_8x8` bir `start` isteğini yalnız `start_ready=1` iken kabul eder. Ağırlık ve
aktivasyon girişleri ayrı `valid/ready` kanallarıdır; ikisi de 64-bit, yani sekiz INT8 lane.
`active_rows`, `active_cols` ve `k_len` ile daha küçük tile'lar çalıştırılabilir. Çıkış tarafı
`out_valid`/`out_ready` ile akar: `out_acc_flat` (8×INT32), `out_lane_valid`, `out_col`,
`out_k_last`, `out_last`. `busy`, `done`, `config_error`, `drain_stall`, `cycle_count` ve
`mac_fire_flat` gözlem sinyalleridir.

Bu portlar doğrulama ve OOC synthesis içindir. Ürün entegrasyonunda önüne banked BRAM/URAM
feeder, arkasına requantizer + output FIFO / AXI-Stream sarmalayıcı konacak.

## Doğrulama

Tüm regresyon — XSim ([[ADR-017 Simülasyon ve Emülasyon Ortamı|ADR-017]]):

```powershell
python sim\run_tests.py                # hepsini koş
python sim\run_tests.py tb_pe_os       # yalnız adı verilenleri koş
python sim\run_tests.py --list         # bulunan testleri listele
```

Bir test ancak XSim 0 ile çıkar, çıktısında `PASS` bulunur ve hiçbir hata işareti
bulunmazsa yeşil sayılır — hata yokluğu tek başına başarı sayılmaz. Vivado yolu
`$VIVADO_BIN`, `$XILINX_VIVADO/bin` veya bilinen kurulum yollarından bulunur.

Son durum (2026-09-27): **6/6 PASS**.

> **Not:** ADR-009 başlangıçta cocotb + Icarus seçmişti çünkü Vivado'nun bulunmadığı
> varsayılmıştı. Vivado kurulu ve XSim hem SystemVerilog assertion'larını hem şifreli
> Xilinx IP'sini kaldırıyor; Icarus ikisini de kaldıramıyor. ADR-017 bu yüzden tek
> simülatöre geçti ve `tb/cocotb/` kaldırıldı.

Bağımsız cycle model (simülatör gerektirmez):

```powershell
python model\verify_architecture.py
```

## Vivado

GUI projesi. `vivado/.project/` altında kurulur ve commit edilmez — ADR-001 projeyi ham
dosya değil Tcl olarak saklar, dolayısıyla kanonik kaynak bu script'tir:

```powershell
vivado -source vivado\create_project.tcl
```

Script varsa mevcut projeyi yeniden açar, yoksa sıfırdan kurar: tüm `rtl/*.sv` +
`tb/*.sv`, XDC, synth top `systolic_array_8x8`, sim top `tb_compute_engine`. `$readmemh`
vektörleri için sim dizinine bir junction atar, böylece `tb_requant_unit_num` GUI'de de
koşar.

Out-of-context synthesis kapısı:

```powershell
vivado -mode batch -source vivado\check_synth.tcl
```

Kabul şartı `DSP48E1=64` ve 100 MHz için negatif olmayan WNS'dir. `use_dsp` özniteliği tek
başına kanıt sayılmaz; Tcl kontrolü bu nedenle sentezlenmiş netlistte gerçek primitive
sayısını denetler. Son ölçüm (2026-09-26, Vivado 2025.1): **64 DSP48, WNS +3.074 ns @
100 MHz**, 1160 LUT / 960 FF / 0 BRAM.

## Bilinen sınırlar

- **Entegrasyon yok.** `window_gen`/`line_buffer`, `requant_unit` ve `axi_lite_regs` top'a
  bağlı değil, dolayısıyla sentez ve STA kapsamı dışında. ADR-014'ün `LAT` değeri gerçek
  bir STA sonucuyla kilitlenmeli.
- AXI backpressure çekirdeğin ortasında uygulanmaz; çalışma başladıktan sonra banked
  feeder'ın kesintisiz veri garantisi gerekir.
- `window_gen` Aşama 1 kontratı `PAD=0`'dır. Sıfır dolgu üretiliyor ama sıfır olmayan dolgu
  için DMA/frame kontratında açık bir kenar politikası ve ayrı doğrulama vektörleri gerekir.
- Ağırlıklar bitstream'e gömülü ([[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]); çalışma
  zamanında ağırlık yükleme ADR-012'ye bağlı ve Aşama 2 başında karara bağlanacak.
