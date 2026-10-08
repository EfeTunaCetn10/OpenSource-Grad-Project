---
title: ADR-017 Simülasyon ve Emülasyon Ortamı
created: 2026-09-26
modified: 2026-09-26
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, verification, xsim, vitis, pynq, emulation]
---

# ADR-017: Simülasyon ve Emülasyon Ortamı

## Durum
Kabul edildi — 2026-09-26. Bu ADR [[ADR-009 Doğrulama Ortamı|ADR-009]]'un simülatör
seçimini **değiştiriyor** (Katman 1 artık Icarus değil XSim) ve "Vitis ile emülasyon"
seçeneğini kanıtla eliyor.

## Bağlam

İki soru cevapsızdı ve ikisi de planı doğrudan değiştiriyordu:

1. **Bu makinede ne kurulu?** [[🔮 850-Companion/Threads|Threads]] 2 Eylül'den beri
   "bu makinede hiçbir HDL simülatörü veya Vivado kurulu değil, RTL hiç koşmadı" diyordu.
   [[ADR-009 Doğrulama Ortamı|ADR-009]]'un cocotb+Icarus kararı bu varsayım üzerine kuruldu.
2. **PS tarafı simülasyonu nerede yapılır?** "PYNQ ile mi Vitis ile mi emüle edelim"
   sorusunun içinde bir kategori hatası vardı; aşağıda açılıyor.

## Ölçüm — 2026-09-26, bu makinede

Threads'teki varsayım **bayattı**. Doğrulanan durum:

| Araç | Durum | Kanıt |
|---|---|---|
| Vivado 2025.1 | **Kurulu** | `C:\Vivado\2025.1\Vivado\bin`, `xvlog`/`xelab`/`xsim` çalışıyor (`Vivado Simulator v2025.1.0`) |
| `xc7z020` parça desteği | **Var** | `data/parts/installed_devices.txt` → `zynq` listesinde `xc7z020` |
| `axi_vip`, `axi4stream_vip` | **Var** | `data/ip/xilinx/axi_vip_v1_1`, `axi4stream_vip_v1_1` |
| `processing_system7_vip` | **Var** | `data/ip/xilinx/processing_system7_vip_v1_0` |
| `axi_dma`, `blk_mem_gen`, `processing_system7` | **Var** | `axi_dma_v7_1`, `blk_mem_gen_v8_4`, `processing_system7_v5_5` |
| Vitis embedded (Cortex-A9) | **Var** | `cpu_cortexa9_v2_13`, `standalone` BSP, **`axidma_v9_19`**, `scugic`, `uartps` |
| Icarus Verilog, Verilator, cocotb, make, numpy | **Yok** | `command -v` → yok; `import cocotb/numpy` → ModuleNotFoundError |
| Vitis acceleration platformu | **Yok** | kurulu platformlar `achromatic`, `blanche` (ikisi Versal); 7-series platform yok |
| XRT | **Yok** | `Vitis/` altında hiç `*xrt*` yok |

**RTL ilk kez simüle edildi (2026-09-26).** 7 kaynak `xvlog -sv` ile temiz derlendi;
`tb_pe_os` → `PASS`, `tb_systolic_array_8x8` → `PASS: all tests matched`. Python golden
model'ler de koştu (`requant_ref.py`: 101 tie, 51'i nearest-even'dan ayrışıyor;
`verify_architecture.py`: 4/4 case PASS).

## Karar

### 1. Tek simülatör: XSim. Icarus ve cocotb kurulmayacak.

[[ADR-009 Doğrulama Ortamı|ADR-009]] cocotb+Icarus'u **Vivado'nun yokluğu varsayımıyla**
seçmişti ve kendi kaydettiği çakışmayı (cocotb XSim'i desteklemiyor, Icarus şifreli Xilinx
IP'sini simüle edemiyor) iki ayrı katmana bölerek çözmüştü. Vivado elde olunca çakışmanın
**sebebi ortadan kalkıyor**: XSim hem saf RTL'i hem SVA'yı hem şifreli Xilinx IP'sini
koşturur. İki simülatör yerine bir simülatör.

Kaybedilen tek şey cocotb'nin Python sürücüsüdür. ADR-009'un kendi **dosya tabanlı köprü**
kararı bunu zaten karşılıyor: golden model simülatörün içinde canlı olmak zorunda değil,
Python vektör üretir → `$readmemh` okur → karşılaştırma testbench içinde yapılır.

Kazanç sadece sadeleşme değil: cocotb+Icarus yolunda `T_NUM_REQ_001` 11 Eylül'de yazıldı ve
**15 gün boyunca hiç koşmadı** çünkü iki araç da kurulu değildi. Kurulum engeli olan bir
doğrulama altyapısı, doğrulama altyapısı değildir.

**Regression koşucusu:** `systolic-array-8x8/sim/run_tests.py` — `rtl/` ve `tb/` altındaki
her kaynağı derler, `tb_*` ile başlayan her modülü elaborate edip koşar, PASS/FAIL tablosu
basar, hata varsa sıfırdan farklı döner. Vivado'yu kendisi bulur. Tek komut:
`python sim/run_tests.py`.

> Bir test yalnız **PASS satırı yazarsa** geçer. Hatanın yokluğu başarı sayılmaz: erken
> biten bir XSim koşusu da 0 döner.

### 2. Üç doğrulama kademesi, hepsi XSim

| Kademe | Ortam | Ne doğrular | Kart |
|---|---|---|---|
| **1** | XSim, saf RTL + dosya vektörü | Birim aritmetiği, golden model bit-exact karşılaştırması (`T_NUM_REQ_001`, `T_NUM_OVF_001`) | gerekmez |
| **2** | XSim + `axi_vip` (AXI4-Lite master) + `axi4stream_vip` | IP kontratı: register map ve shadow/commit (`T_REG_PARAM_001`), AXIS backpressure/TLAST (`T_AXI_BP_001`), byte lane (`T_AXI_LANE_001`) | gerekmez |
| **3** | XSim + `processing_system7_vip` + `axi_dma` + blok tasarım | Uçtan uca: PS register yazar → commit → DMA descriptor → DDR→AXIS→IP→S2MM→DDR → PS okur | gerekmez |
| **4** | Kart: PYNQ Python overlay | Gerçek donanım doğruluğu, tüm test seti | gerekir |
| **5** | Kart: Vitis bare-metal C | ADR-015'in AXI4-Lite yazma gecikmesi ölçümü | gerekir |

Kademe 1'den başlanır. Kademe 3, [[Roadmap]] §3'ün "ilk entegrasyon topolojisi"ni
(`DDR → MM2S → pass-through → S2MM → DDR`) önce loopback olarak kurar, sonra pass-through
yerine hızlandırıcıyı koyar.

**`processing_system7_vip` C kodu koşturmaz.** SystemVerilog task'larıyla sürülür ve bir DDR
bellek modeli sağlar. Yani "PS tarafını simüle etmek", sürücünün yapacağı register yazma +
DMA kurulum **dizisini** SV'de yazmak demektir. O dizi Kademe 3'te doğrulanır, sonra aynı
dizi PYNQ Python'da (Kademe 4) ve C'de (Kademe 5) yeniden yazılır. Sürücü mantığı zaten bir
diziden ibarettir; kaybedilen bir şey yoktur.

### 3. "Vitis ile emülasyon" elendi — tooling eksiği değil, akış uyuşmazlığı

Vitis'in `hw_emu`/`sw_emu` emülasyonu **Vitis acceleration flow**'a aittir: `v++` ile
derlenmiş kernel + XRT runtime + `.xpfm` platform. Üç bağımsız sebeple bu projeye kapalı:

1. **Zynq-7000 acceleration flow hedefi değil.** Kurulu platformlar Versal (`achromatic`,
   `blanche`); 7-series platform yok, XRT yok. Platform olmadan `v++`/`emconfigutil` çalışmaz.
2. **Proje mimari olarak o akışta değil.** Elde custom RTL IP + AXI DMA + klasik block
   design var; `v++` kernel'i yok. Acceleration flow'a taşımak
   [[ADR-007 DMA Modu|ADR-007]]'nin AXI DMA + AXI4-Lite kararını düşürür ve RTL'i baştan
   yazdırır.
3. **QEMU PL'i modellemez.** Vitis embedded tarafındaki QEMU PS'i koşturur ama programmable
   logic'i simüle etmez — yani C kodu çalışır, hızlandırıcı ortada yoktur. Hızlandırıcıyı
   doğrulamaz.

### 4. PYNQ bir emülasyon ortamı değil, kart yoludur

PYNQ = kartın Cortex-A9'unda koşan Ubuntu + Python. Simülatörü yoktur; denemek karta SD kart
takmak demektir. PYNQ **Kademe 4**'tür ve kart üstü bring-up'ın en kolay yoludur
([[ADR-007 DMA Modu|ADR-007]] zaten bu varsayımla yazıldı). Vitis bare-metal C ise
**Kademe 5**'tir. İkisi de yazılım tarafıdır, simülasyon tarafı değildir.

**Sıra:** PYNQ ile doğruluk kapatılır, sonra aynı register map üzerine bare-metal C yazılır.
Register offset'leri tek kaynaktan üretilir ve iki tarafta paylaşılır — ADR-015'in tablosu
elle iki kez yazılmaz.

## Sonuçlar

- [[ADR-009 Doğrulama Ortamı|ADR-009]]'un "Katman 1 = cocotb + Icarus Verilog" maddesi
  **düşürüldü**; Katman 1 ve 2 ayrımı korunuyor ama ikisi de XSim'de. ADR-009'un
  "CI'da yalnızca Katman 1 koşabilir (Icarus ücretsiz ve headless)" maddesi de düşüyor:
  XSim headless koşar ama Vivado kurulumu gerektirir, yani ücretsiz public CI'da koşmaz.
  **CI bu projede lokal regression demektir** — `sim/run_tests.py`, her commit öncesi.
- `tb/cocotb/` (Makefile + `test_requantizer.py`) artık ölü yol. Silinmeden önce içindeki
  vektör kapsamı SV testbench'e taşınmalı; kapsam kaybı olmadan retire edilecek.
- ADR-009'un asıl değerli kararı — **dosya tabanlı golden model köprüsü** — aynen geçerli ve
  artık tek simülatörde daha da doğal.
- Kademe 3 mümkün olduğu için "uçtan uca çalışan sistem" kart gelmeden kanıtlanabilir; kart
  adımı doğrulama değil **teyit** olur.
- Aşama 1'in bitiş hâli **tam ağ** (5 katman) olarak kesinleşti (2026-09-26, Emin) —
  [[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]'nın açık bıraktığı çok
  katmanlı ara aktivasyon düzeni artık kilitlenebilir durumda.

## Alternatifler

- **Icarus/Verilator kurup ADR-009'da kalmak:** iki simülatör, iki testbench dili, ve
  Kademe 2/3 zaten Icarus'ta imkânsız. Vivado elde olduğu için tek kazancı cocotb'nin
  Python'u; dosya köprüsü bunu karşılıyor. Elendi.
- **Vitis acceleration flow + hw_emu:** yukarıdaki üç sebep. Elendi.
- **Yalnız kart üstünde doğrulamak (simülasyonu atlamak):** [[Roadmap]] §19'un en pahalı
  hata sınıfı; kartta gözlenebilirlik yok, `y_raw` gibi pre-clamp iç sinyaller hiç
  görülemez. Elendi.
