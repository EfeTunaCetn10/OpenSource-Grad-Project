---
title: Systolic Array RTL İncelemesi
created: 2026-09-02
modified: 2026-09-02
type: note
status: active
tags: [dnn-accelerator, review, rtl, systolic-array, verification]
---

# Systolic Array RTL İncelemesi — 2026-09-02

> [!info] Bu bir ADR değil
> Burada **karar alınmıyor**, dış kaynaklı bir RTL paketi değerlendiriliyor. Bağlayıcı kararlar
> `ADR-*.md` dosyalarında. Bu notun ürettiği karar önerileri henüz ADR'ye dönüşmedi — bkz.
> [[#Buradan çıkan ADR adayları]]. İncelenen kod `systolic-array-8x8/` klasöründe **olduğu gibi**,
> değiştirilmeden duruyor.

## Ne incelendi

Sol 5.6'nın temiz-kaynak yazdığı 8×8 output-stationary systolic array paketi: 11 dosya,
1040 satır SystemVerilog + Python. `systolic-array-8x8/` altında.

```
systolic_array_8x8.sv        ← Vivado OOC synthesis top (sabit 8×8)
└─ systolic_tile_engine.sv   ← tile yakalama + skew + clear/run/capture FSM
   └─ systolic_array_os.sv   ← parametrik ROWS×COLS mesh
      └─ pe_os.sv ×64        ← MAC hücresi
```

Yanında: iki SystemVerilog testbench, bağımsız Python cycle modeli, Vivado OOC sentez kontrol
script'i ve bir tasarım/repo inceleme dokümanı (`tasarim-ve-repo-incelemesi.md` — oradaki
10 repo tarama tablosu [[ADR-004 Systolic Array Boyutu|ADR-004]]'ün kendi taramasını
tamamlıyor, saklamaya değer).

## Doğrulama yöntemi ve sonucu

Paketin kendi iddiası "pyslang 11.0 ile 0 hata, 0 uyarı" — bu **parse + elaborate** sonucudur,
simülasyon veya sentez değil. Bu makinede iverilog, verilator ve vivado kurulu olmadığı için
paket hâlâ hiçbir HDL simülatörü görmedi.

Bu boşluğu kapatmak için `pe_os.sv` + `systolic_array_os.sv` + `systolic_tile_engine.sv`
Python'da **cycle-faithful olarak yeniden yazıldı** (Sol'un kendi `verify_architecture.py`
modelinden bağımsız — o model de ayrıca koşuldu ve geçti) ve golden GEMM ile karşılaştırıldı:

| Test | Sonuç |
|---|---|
| 8×8 K=8 | ✅ 512/512 MAC |
| 3×5 K=7, 8×2 K=5, 2×2 K=2 (partial tile) | ✅ |
| 8×8 K=1, 1×8 K=8, 8×1 K=8 (dejenere şekiller) | ✅ |
| 1×1 K=1 | ✅ |
| Tüm elemanlar `-128 × -128` | ✅ 131072 |
| **Toplam** | **0 hata** |

Skew formülü, `run_last = K+R+C-3`, partial-tile maskeleme, signed aritmetik, `config_error`
ve bit genişlikleri (`RUN_W=5`, max `run_last=21`, taşma yok) — hepsi doğru.
**Fonksiyonel bir hata bulunamadı.**

## Mimari — neyi neden yapıyor

### PE

```
a_in ──┬──────────────────► [a_out reg] ──► sağdaki PE
       ├──► signed 8×8 mult ──► sign-ext 16→32 ──┐
b_in ──┤                                          ▼
       │                          clear_acc ──► [+] ◄── acc_reg (32b)
       └──────────────────► [b_out reg] ──► aşağıdaki PE     CE = mac_fire

mac_fire = step & a_valid & b_valid & !clear_acc & !pipe_flush
```

**Tasarımın en değerli kısmı: A ve B için ayrı `valid` zincirleri.** Çoğu öğrenci tasarımı
(ve taranan repolardan ridash'ınki) valid taşımaz, "sıfır besle, çarpım sıfır olur" der.
Bu iki yerde çöker:

1. **Partial tile'da** — inaktif kolonlara sıfır beslenirse sonuç doğru çıkar ama MAC sayacı
   yalan söyler; utilization ölçülemez ve hata sessizce gizlenir.
2. **Asimetrik quantization'a geçilirse** ([[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün
   yazılı kaçış kapısı) sıfır artık nötr eleman değildir; valid'siz tasarım o gün RTL
   değişikliği ister.

`mac_fire` dışarı çıkarılmış — hem performance counter kaynağı hem de doğrulama kancası:
testbench `Σ mac_fire == rows×cols×K` kontrolünü yapıyor. "Sonuç doğru ama yanlış sebeple
doğru" hatasını yakalayan tek mekanizma budur.

`step` bir clock enable (CE), combinational clock gating değil —
[[ADR-008 Clock Domain Stratejisi|ADR-008]]'in tek domain kararıyla uyumlu.
`clear_acc` (yalnız accumulator) ile `pipe_flush` (yalnız forwarding register'ları) ayrı
tutulmuş; K-tile accumulation'da accumulator'ı koruyup pipeline'ı boşaltmak gerekeceği için
bu iyi bir öngörü — ama şu an tile engine ikisini de aynı sinyalden sürüyor, `pipe_flush`
top seviyede ölü bir düğme.

### Mesh ve skew

- `A[r,k]` sol kenardan **t = r+k** anında girer
- `B[k,c]` üst kenardan **t = c+k** anında girer
- A, `PE[r,c]`'ye c register gecikmesiyle → **t = r+k+c**
- B, `PE[r,c]`'ye r register gecikmesiyle → **t = c+k+r**
- İkisi aynı anda buluşur. Skew'un tek sebebi bu.

Skew olmasa `PE[3,5]`'te A'nın k=0 elemanı B'nin k=8 elemanıyla çarpılırdı. Son MAC
t = K+R+C−3; run penceresi K+R+C−2 = **22 çevrim** (8×8, K=8).

### Operand mapping — ADR-011 ile bağ

Doğru eşleme (paket bunu dokümante etmemiş ama RTL destekliyor):

| Kenar | Anlam | Kaynak |
|---|---|---|
| **A** (sol, satır r) | **ağırlık**, r = `c_out mod 8`, k = `c_in·kH·kW` | [[ADR-011 Ağırlık Bellek Adresleme\|ADR-011]]'in 8 bankası |
| **B** (üst, kolon c) | **aktivasyon**, c = çıktı piksel pozisyonu | window generator ([[ADR-005 Direct Convolution\|ADR-005]]) |
| **C[r][c]** | output kanal r, piksel c | requantizer'a |

`a_matrix_flat` layout'u (ROWS×K_MAX row-major) ADR-011'in `addr(bank=r, tile=t, k) = t*K + k`
formülüyle **birebir aynı**. Dönüşüm gerekmiyor.

> [!warning] ADR boşluğu — aktivasyon feeder'ı
> ADR-011 yalnızca ağırlık tarafını bankalıyor. Ama t anında 8 kolonun 8 **farklı** k değerine
> ihtiyacı var (`k = t−c`), yani aktivasyon feeder'ı da 8 bankalı ve skew'lu olmak zorunda.
> Bunun ADR'si yok. Gerçek entegrasyon maliyeti burada, ve paket bunu 512-bit paralel port
> olarak kestirip atmış.

## ADR uyum tablosu

| ADR | Karar | Paket | Not |
|---|---|---|---|
| [[ADR-003 INT8 Fixed-Point Formatı\|003]] | INT8×INT8, INT16 product, INT32 acc, signed | ✅ birebir | PE kontratı tam oturuyor |
| [[ADR-003 INT8 Fixed-Point Formatı\|003]] | Requantizer, M0/n, round-half-up | ⚠️ yok | Kapsam dışı, doğru. `T_NUM_REQ_001` hâlâ ilk iş |
| [[ADR-004 Systolic Array Boyutu\|004]] | 8×8, 64 PE, output-stationary | ✅ | |
| [[ADR-005 Direct Convolution\|005]] | Direct conv, im2col yok | ⚠️ nötr | Array core uyumlu; tile engine paralel-load GEMM harness'ı, atılacak |
| [[ADR-006 AXI Stream Paket Semantiği\|006]] | AXI4-Stream 64-bit | ❌ yok | Beklenen |
| [[ADR-007 DMA Modu\|007]] | AXI-Stream + DMA | ❌ yok | Beklenen |
| [[ADR-008 Clock Domain Stratejisi\|008]] | Tek clock domain, sync reset | ✅ | CDC yok, `rst_n` synchronous |
| [[ADR-009 Doğrulama Ortamı\|009]] | cocotb + Icarus (Katman 1) | ❌ **aykırı** | TB'ler düz SystemVerilog; senaryolar iyi, cocotb'ye taşınmalı |
| [[ADR-011 Ağırlık Bellek Adresleme\|011]] | `[c_out][k]` row-major, 8 banka | ✅ **tam uyum** | Adres formülü doğrudan bağlanıyor |

## Bulgular

### P0 — `K_MAX = 8` mimari tavanı

Her `start` bir kez temizler, en fazla 8 uzunluğunda dot product yapar, yakalar, IDLE'a döner.
LeNet-5'te K değerleri: conv1 K=75, conv2 K=150, FC1 K=400.

LeNet-5 (32×32 RGB, batch=1, [[ADR-002 CNN Topolojisi ve Dataset|ADR-002]]) @100 MHz:

| Katman | MAC | İdeal cyc | Bu paketle | Verim |
|---|---|---|---|---|
| conv1 (K=75) | 352.800 | 5.513 | 23.520 | %23 |
| conv2 (K=150) | 240.000 | 3.750 | 11.856 | %32 |
| FC1 (K=400) | 48.000 | 750 | 18.000 | **%4** |
| FC2 | 10.080 | 158 | 3.960 | %4 |
| FC3 | 840 | 13 | 528 | %2 |
| **Toplam** | **651.720** | **10.183** | **57.864** | **%17,6** |

= **579 µs/frame**, ~1,7 kfps. Teorik tavanın 5,7 katı yavaş.

**Düzeltme:** K'yi streaming yap — tile register'ı at, `k_reg`'i sayaca çevir, feeder her
çevrim yeni k'yi getirsin, `clear_acc` yalnız yeni output tile'da assert edilsin.
→ 21.170 cyc, **%48 verim, 2,7× kazanç. PE'de sıfır değişiklik**, iş tile engine'de.

### P0 — FC katmanları 64 PE'nin 8'ini kullanıyor

`batch=1` olduğu için FC'de N boyutu = 1; kolon ekseni ölü. K streaming'e geçilse bile FC
toplam sürenin **%37'sini** yiyip MAC'ların yalnız %9'unu yapıyor.

**Düzeltme:** FC için ayrı mod — K'yi 8 kolona böl (`PE[r][c]` = output kanal r, K-chunk c),
sonda 8 girişli 32-bit adder tree ile kolonları topla. Adder tree ~250 LUT, kazanç büyük:
FC toplamı 7.936 → 1.359 cycle.

**Her iki düzeltmeyle: 14.593 cyc = 146 µs/frame, %70 verim.** Savunulabilir bir sayı.

> [!important] Bunlar "optimizasyon" değil
> Paketin kendi dokümanı bu iki maddeyi "P1" diye geçiştirmiş. Değiller — mimarinin kendisi.
> Aşama 2'ye ertelenirse tile engine baştan yazılır.

### P1 — `check_synth.tcl` bozuk

```tcl
synth_design ...          ← constraint YOK, unconstrained sentez
create_clock -period 10   ← ÇOK GEÇ
report_timing_summary     ← anlamsız rapor
```

Clock `synth_design`'dan **önce** bir XDC ile verilmeli, yoksa Vivado timing-driven
optimizasyon yapmaz. Ayrıca README "kabul şartı DSP=64 **ve** WNS≥0" diyor ama script yalnız
DSP sayıyor, WNS'i hiç kontrol etmiyor. İkisi de 5 satırlık düzeltme.

### P1 — ADR-008'in fMAX marj gerekçesi bu PE'ye uymuyor

ADR-008 "DSP48E1 fMAX ~241 MHz, 2,4× marj" diyor. O rakam **tam pipeline'lı**
(AREG+BREG+MREG+PREG) DSP için. Bu PE'de A/B register'ları komşu PE'de, MREG yok — DSP
`A → mult → add → P` kombinasyonel yolunda çalışacak, -1 grade'de ~5-6 ns. 10 ns'i tutar
ama marj ~1,5×. Kritik yol muhtemelen array değil, skew feeder'ın
`a_tile_reg → 8:1 mux → PE[r][0] → DSP → P` yolu olacak.
**Gerçek sentez koşulana kadar ADR-008'in marj gerekçesi kanıt sayılmamalı.**

### P2

- Peak **48 MAC/cycle** (64 değil): K=8'de dalga cephesi array'i geometrik olarak dolduramıyor
  (`r+c` köşegen çokluğunda 8 ardışık değerin toplamı max 48). K ≫ R+C olunca 64'e yaklaşır —
  P0'daki streaming düzeltmesinin ikinci gerekçesi.
- `c_valid` tek çevrimlik, `c_ready` yok; tüketici o çevrimi kaçırırsa sonuç gider.
- Rastgele test yok, yalnız deterministik desenler. ADR-003'ün "rastgele test tie'ı vurmaz"
  dersi burada da geçerli.
- `integer ri, ci, k_index` modül seviyesinde `always_comb` içinde — Verilator lint uyarır,
  `automatic` olmalı.
- Top modül ~3100 pin; yalnız OOC sentez için.

## Dosya bazında karar

| Dosya | Karar |
|---|---|
| `rtl/pe_os.sv` | ✅ **Olduğu gibi al.** Paketin en iyi 79 satırı |
| `rtl/systolic_array_os.sv` | ✅ **Olduğu gibi al.** Temiz generate mesh, parametrik |
| `rtl/systolic_tile_engine.sv` | ⚠️ Skew formülünü kopyala, gerisini at |
| `rtl/systolic_array_8x8.sv` | ⚠️ Yalnız OOC sentez top'u |
| `tb/*.sv` | ⚠️ Senaryolar iyi (signed sınır, partial tile, MAC sayımı, stall, flush) — cocotb'ye taşı |
| `model/verify_architecture.py` | ✅ Golden model iskeleti |
| `vivado/check_synth.tcl` | ⚠️ Fikri doğru, uygulaması bozuk — düzelt |
| `tasarim-ve-repo-incelemesi.md` | ✅ Repo tarama tablosu sakla |

## Buradan çıkan ADR adayları

1. **K streaming vs K-tile accumulation** — P0'ın birinci maddesi. `ADR-012` (runtime ağırlık
   yükleme) ile aynı Aşama 2 penceresinde ele alınmalı; ikisi de feeder mimarisine dokunuyor.
2. **FC katmanı dataflow'u (K-split + adder tree)** — P0'ın ikinci maddesi. `batch=1`
   ([[ADR-002 CNN Topolojisi ve Dataset|ADR-002]]) doğrudan sebebi, o yüzden ADR-002'ye bağlı.
3. **Aktivasyon feeder bankalama şeması** — ADR-011'in ağırlık tarafına simetrik karşılığı,
   şu an yazılı değil.

## Sıradaki somut iş

1. `T_NUM_REQ_001` — requantizer bit-exact testi, tie vektörleriyle (ADR-003). **Değişmedi.**
2. `pe_os.sv`'yi projeye al, cocotb ile koş, sonra Vivado OOC'de 1 PE = 1 DSP'yi **ölç**
   (`use_dsp` attribute'u tek başına kanıt değil).
3. Tile engine'i yeniden yaz: streaming K + FC için K-split modu.

## Dürüst sınır

Bu incelemedeki fonksiyonel doğrulama Python'da yapılmış cycle simülasyonuna dayanıyor.
Gerçek simülatör davranışı (X-propagation, reset öncesi durum, `initial` blok semantiği) ve
sentez sonuçları (DSP inference, gerçek WNS, LUT/routing) **hâlâ ölçülmedi**. Bu makinede
iverilog/verilator/vivado kurulu değil. Kurulunca ilk koşulacaklar: `tb_pe_os`,
`tb_systolic_array_8x8`, `check_synth.tcl` (düzeltilmiş hâli).

İlgili: [[Kontrat Değerlendirmesi]], [[Roadmap]], [[Proje Kararları]]
