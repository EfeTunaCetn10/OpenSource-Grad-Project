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
- `rtl/systolic_array_8x8.sv`: 64 PE'li sabit isimli compute-core synthesis top'u;
  `compute_engine`'i 8×8 / `K_MAX=1024` ile sarar.

### RTL — conv1 entegrasyon top'una bağlı

`rtl/conv1_top.sv` LeNet-5 conv1'in uçtan uca veri yolu: `window_gen` → `layer_ctrl` →
(`weight_feeder` + `compute_engine`) → `requant_array`. 2026-10-07'de XSim'de **bit-exact**
doğrulandı (`tb_conv1_top`, `T_CONV1_E2E_001`) ve `vivado/check_synth_conv1.tcl` ile
sentezden geçirildi. Ara aktivasyon tamponunu **içermiyor**: fiziksel layout
[[ADR-018 K-Streaming ve Ara Aktivasyon Düzeni|ADR-018]]'de 2026-10-07'de kilitlendi ama
address generator henüz yazılmadı, requant stream'i doğrudan dışarı çıkıyor.

- `rtl/line_buffer.sv`: Sekiz bankalı, banka başına tek okuma portlu satır tamponu.
- `rtl/window_gen.sv`: Parametrik valid-convolution pencere üreticisi
  (`K_H`, `K_W`, `C_IN`, `IN_W`, `IN_H`, `STRIDE`, `PAD`). Çıkış sırası output-row →
  sekiz kolonluk tile → `k = ci*(K_H*K_W) + kh*K_W + kw`; her beat aynı `k`'deki sekiz
  pozisyonu taşır ve `compute_engine`'in B-top aktivasyon kenarına birebir oturur.
- `rtl/weight_feeder.sv`: [[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] ağırlık kenarı —
  sekiz bağımsız banka, `bank = c_out mod 8`, ortak adres `tile_idx*K + k`, senkron BRAM
  okuması + iki girişli elastic FIFO (coupled handshake altında beat kaybı/duplikasyonu yok).
- `rtl/layer_ctrl.sv`: Tile sequencer. `window_gen`'in beat metadata'sını `compute_engine`
  ve `weight_feeder` için `start` komutlarına çeviriyor; `active_cols`'u tile'ın henüz kabul
  edilmemiş ilk beat'inden örnekliyor, CLEAR cycle'ını bekliyor, sekiz bitlik sticky
  `error_flags` üretiyor.
- `rtl/requant_unit.sv` / `rtl/requant_array.sv`: ADR-003 / ADR-014 INT32→INT8 requantizer
  ve sekiz lane'lik lockstep sarmalayıcısı. `LAT = 5` artık ölçülmüş
  ([[ADR-014 Requantizer Port ve Zamanlama Sözleşmesi|ADR-014]]).

### RTL — hâlâ hiçbir top'a bağlı değil

- `rtl/axi_lite_regs.sv`: [[ADR-015 Register Map ve Parametre Yükleme|ADR-015]] AXI4-Lite
  register file'ı — shadow + commit protokolü, `ERR_CFG_M0`, W1C bitleri. Birim testi yeşil
  ama datapath'e bağlayan sarmalayıcı yazılmadı, yani sentez ve STA kapsamı dışında.
  `conv1_top`'un `cfg_*` portlarını Aşama 1'de testbench sürüyor.

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
- `tb/tb_requant_array.sv`: Sekiz lane lockstep, mask değişen tile fazı (MIXMASK), BP,
  partial-K, saturation/overflow ve bypass.
- `tb/tb_weight_feeder.sv`: Banka/adres eşlemesi byte byte, 1/2/çok cycle backpressure,
  farklı `k_len` ve `tile_idx` ile ardışık tile'lar, `cfg_error` yolları.
- `tb/tb_layer_ctrl.sv`: Gerçek `compute_engine` ile tile sequencing; `active_cols` 8→4,
  generator boşlukları, ağırlık açlığı, DRAIN backpressure ve sekiz `error_flags` bitinin
  tamamı.
- `tb/tb_conv1_top.sv`: `T_CONV1_E2E_001` — conv1 uçtan uca. 112 tile, 784 output beat ve
  784 INT32 accumulator beat `model/conv1_ref.py` golden'ına karşı bit-exact; aynı frame
  iki farklı backpressure deseniyle iki kez koşuluyor.

### Golden model ve araçlar

- `model/verify_architecture.py`: Bağımsız cycle model ve golden matrix multiplication kontrolü.
- `model/engine_ref.py`: K-streaming motorunun stdlib-only golden modeli.
- `model/window_ref.py`: HWC aktivasyon pencere akışının golden modeli.
- `model/requant_ref.py`: ADR-003 requantization golden modeli; `python model/requant_ref.py`
  kendi kendini doğrulayan bir kontrol de çalıştırır.
- `model/gen_requant_vectors.py`: `T_NUM_REQ_001` için `$readmemh` vektörlerini üretir.
  Vektörler deterministik ve ~4 MB olduğu için commit edilmiyor; `run_tests.py` eksikse
  kendisi üretir.
- `model/conv1_ref.py`: conv1 uçtan uca golden'ı. Yeni aritmetik yok — `window_ref`,
  `engine_ref` ve `requant_ref` compose ediliyor; `python model/conv1_ref.py` kendi
  kendini doğrular (bir output'u frame'den doğrudan yeniden hesaplayıp karşılaştırır).
- `model/gen_conv1_vectors.py`: `T_CONV1_E2E_001` vektörleri (`c1_*.mem`) — frame, sekiz
  ağırlık bankası, per-lane requant config, tile geometrisi, beklenen accumulator ve INT8
  beat'ler. Lane 0 = low byte packing (`[01..08]` → `0807060504030201`).
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

Son durum (2026-10-07): **10/10 PASS** (XSim 2025.1).

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

Conv1 entegrasyon kapısı (ayrı top, ayrı kapı):

```powershell
vivado -mode batch -source vivado\check_synth_conv1.tcl
```

Bu kapı `conv1_top`'u sentezler, 80 DSP48 (64 PE + 16 requant) ve negatif olmayan WNS
arar, bellek realizasyonunu raporlar ve ağırlık bankalarının gerçekten block RAM olarak
kurulduğunu kontrol eder (instance'ın var olması yetmez — boş kabuk da sayılır).

Son ölçüm (2026-10-07, Vivado 2025.1, xc7z020clg400-1, 100 MHz): **PASS** —
80 DSP48, 16 RAMB36, **WNS +1,203 ns**, 5013 LUT / 4033 FF.
Kritik yol artık `u_ctrl/cfg_k_reg` → `u_weights/beats_accepted/CE`, 8,544 ns,
10 logic level (route %61,9).

Buraya nasıl gelindiği kayda değer, çünkü ilk entegrasyon STA'sı **WNS −33,324 ns**
vermişti (3935 failing endpoint, TNS −112.987 ns; kritik yol `u_window/k_count` → PE
accumulator, 67 logic level / 38 CARRY4 / 42,790 ns). Üç sebep vardı ve üçü de daha önce
hiç sentezlenmemiş kodda:

| Düzeltme | WNS | `conv1_top` LUT / FF |
|---|---:|---:|
| İlk entegrasyon (bulunduğu hâl) | −33,324 ns | 10947 / 7476 |
| `window_gen` bölme/modulo → sayaç, `line_buffer` senkron okuma | +0,075 ns | 6681 / 7825 |
| `line_buffer` ring'i banka başına ayrı diziye | **+1,203 ns** | **5013 / 4033** |

`window_gen` tek başına 6148 → **347 LUT**, `line_buffer` 3951 LUT + 3985 FF →
**314 LUT + 169 FF + 96 LUTRAM**. 32-bit `integer` aritmetiği ve iki boyutlu bellek
dizileri bu tasarımda ölçülebilir bedel: ilki CARRY4 zinciri, ikincisi RAM yerine
flip-flop.

Tam implementation (opt/place/phys_opt/route + post-route setup ve hold):

```powershell
vivado -mode batch -source vivado\check_impl_conv1.tcl
```

Son ölçüm (2026-10-07): **PASS** — post-route setup **WNS +0,920 ns**, hold
**WHS +0,050 ns**, 80 DSP48, 16 RAMB36, 4918 LUT / 4033 FF. DRC temiz.
`conv1_top` 100 MHz'i gerçekten kapatıyor; bu tahmin değil route edilmiş netlist.

## Bilinen sınırlar

- **Hold payı ince.** Post-route setup +0,920 ns rahat, ama hold **+0,050 ns**. 100 MHz'de
  hold tipik olarak sorun değil ve router'ın işi, ama bu sayı block design'a girdikten sonra
  (gerçek clock ağacı, OOC değil) yeniden ölçülmeli.
- **Throughput darboğazı array değil window generator.** `tb_conv1_top` ölçümü: conv1
  frame'i **85.232 engine cycle**, yani 100 MHz'de **852 µs**. Zamanın neredeyse tamamı
  aktivasyon beat'i başına on cycle'lık gather'da geçiyor (8400 beat × 10); 64 PE'nin
  cycle başına bir beat yutabildiği düşünülürse array ~%10 doluluk görüyor. Senkron
  okumaya geçiş bunu 9 cycle'dan 10'a çıkardı (+%10,8, 76.944 → 85.232), karşılığında
  WNS −33,5 ns'den +1,2 ns'ye geldi. Hızlandırmanın yolu gather'ı sekiz bankadan paralel
  okumaktır (ring zaten sekiz banka), ama o Aşama 2 işi ve doğruluk önce.

- **Ağırlık bankaları artık BRAM — kapandı 2026-10-07.** Önceki hâlinde bankaların ne
  initialization'ı ne write port'u vardı, sentez onları sabit bellek sayıp **tamamen
  optimize ediyordu** (`u_weights` utilization raporunda hiç görünmüyordu) — simülasyon
  yeşildi çünkü testbench bankaları hiyerarşik dolduruyordu, yani "sim geçiyor, donanımda
  ağırlık yok" sınıfı. Üç adımda çözüldü: boundary'ye `w_wr_*` load portu
  ([[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] preload'unun RTL karşılığı, ADR-012'nin de
  kancası); iki boyutlu dizinin BRAM inference'a girmediğinin ölçülmesi
  (`Synth 8-11357`, 524.288 register); ve belleğin banka başına ayrı tek boyutlu diziye
  (`g_bank[r].bank_mem`) senkron okumayla taşınması. Ölçüm: **RAMB36 = 16**, banka başına
  tam 2. Testbench'ler bankaları artık `wr_*` portundan yüklüyor, yani yükleme yolu da
  test ediliyor.
- **Ara aktivasyon tamponu yok.** Fiziksel layout 2026-10-07'de kilitlendi (padded
  tile-major, [[ADR-018 K-Streaming ve Ara Aktivasyon Düzeni|ADR-018]] ek maddesi) ama
  address generator, ping-pong takası ve `line_buffer`'ın `C_LOGICAL`/`C_PHYS_STRIDE`
  ayrımı henüz yazılmadı. `conv1_top` bu yüzden requant stream'ini doğrudan dışarı veriyor.
- **Conv2 replay yok.** Bir output-position tile'ının activation `K` akışı iki channel
  tile'da kullanılmalı; `window_gen`'de rewind/replay portu yok. `layer_ctrl` Aşama 1'de
  tek channel tile ile çalışıyor ve kancanın yerini yorumla işaretliyor.
- **Frame lifecycle.** `window_gen`'in `ST_DONE`'u terminal: ikinci frame yalnız `rst_n`
  ile başlıyor. `axi_lite_regs` bir `soft_reset` üretiyor ama `conv1_top`'a bağlı değil.
  `tb_conv1_top` ikinci frame'i bilerek reset'ten sonra koşuyor.
- `axi_lite_regs` hâlâ datapath'e bağlı değil; `conv1_top`'un `cfg_*` portlarını testbench
  sürüyor.
- AXI backpressure çekirdeğin ortasında uygulanmaz; çalışma başladıktan sonra banked
  feeder'ın kesintisiz veri garantisi gerekir.
- `window_gen` Aşama 1 kontratı `PAD=0`'dır. Sıfır dolgu üretiliyor ama sıfır olmayan dolgu
  için DMA/frame kontratında açık bir kenar politikası ve ayrı doğrulama vektörleri gerekir.
- Ağırlıklar bitstream'e gömülü ([[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]); çalışma
  zamanında ağırlık yükleme ADR-012'ye bağlı ve Aşama 2 başında karara bağlanacak.
