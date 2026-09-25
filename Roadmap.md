---
title: FPGA Tabanlı Edge AI Hızlandırıcı — Bitirme Projesi Yol Haritası
aliases:
  - FPGA Edge AI Bitirme Projesi
  - CNN Accelerator Yol Haritası
  - Proje KararlarıV2.0
tags:
  - fpga
  - edge-ai
  - rtl
  - systolic-array
  - axi
  - cnn
  - verification
  - bitirme-projesi
status: planning
created: 2026-08-28
---

# FPGA Tabanlı Edge AI Hızlandırıcı — Bitirme Projesi Yol Haritası

> [!abstract] Proje fikri
> Zynq benzeri bir SoC FPGA üzerinde, AXI DMA aracılığıyla görüntü alan, LeNet-5 benzeri nicemlenmiş bir CNN'i PL tarafındaki systolic-array tabanlı hızlandırıcıda çalıştıran ve sınıflandırma sonucunu PS tarafına döndüren uçtan uca bir Edge AI sistemi geliştirmek.

## İçindekiler

- [[#1. Ana mühendislik yaklaşımı]]
- [[#2. Önerilen minimum proje kapsamı]]
- [[#3. Sistem mimarisi]]
- [[#4. Dört referans modeli]]
- [[#5. RTL geliştirme sırası]]
- [[#6. Tasarım sözleşmeleri]]
- [[#7. AXI ve DMA entegrasyonu]]
- [[#8. CDC, RDC ve metastability]]
- [[#9. Verification stratejisi]]
- [[#10. Zorunlu testler]]
- [[#11. FPGA implementation ve timing closure]]
- [[#12. Performans ölçüm protokolü]]
- [[#13. 16 haftalık çalışma planı]]
- [[#14. Takım iş bölümü]]
- [[#15. Önerilen depo yapısı]]
- [[#16. Okuma listesi]]
- [[#17. Ders ve eğitim serileri]]
- [[#18. Definition of Done]]
- [[#19. Risk listesi]]
- [[#20. Karar kayıtları]]

---

## 1. Ana mühendislik yaklaşımı

Başlangıç noktası RTL değil, **çalıştırılabilir bir tasarım sözleşmesi** olmalıdır. PyTorch modeli, sabit nokta matematiği, AXI paket biçimi, register haritası ve testlerin beklediği sonuçlar RTL geliştirilmeden önce tanımlanmalıdır.

Evrensel tek bir accelerator geliştirme protokolü bulunmaz. Endüstride birden fazla standardın ve metodolojinin birlikte uygulanması söz konusudur:

- Arayüzler için AMBA AXI4, AXI4-Lite ve AXI4-Stream
- RTL için SystemVerilog veya Verilog
- Doğrulama için assertion, functional coverage, randomized testing ve regression
- CDC/RDC için onaylı synchronizer yapıları ve statik analiz
- Sistem geliştirme için gereksinim–tasarım–test izlenebilirliği
- Performans için önceden tanımlanmış ve tekrar üretilebilir benchmark prosedürü

Bitirme projesinde bunların hafifletilmiş fakat gerçekçi bir sürümü uygulanmalıdır.

> [!important] Ana başarı ölçütü
> Başarı yalnızca FPGA'nın doğru sınıfı göstermesi değildir. Aynı girişin PyTorch'tan integer modele, RTL simülasyonuna ve fiziksel FPGA'ya kadar izlenebilmesi; farklılık olduğunda hatanın başladığı katmanın bulunabilmesidir.

---

## 2. Önerilen minimum proje kapsamı

### MVP — Minimum Viable Product

- [x] **PYNQ-Z2** (`xc7z020clg400-1`), Vivado 2024.1 + PYNQ v3.1 — [[ADR-001 Board ve Araç Sürümü]].
- [x] Giriş görüntüsü **32×32 RGB** olacak (`c_in = 3`) — bkz. [[ADR-002 CNN Topolojisi ve Dataset]].
- [x] Aşama 1 için LeNet-5 reference model kullanılacak — 5×5 valid convolution,
  2×2 pooling, 10 sınıf — [[ADR-002 CNN Topolojisi ve Dataset]].
- [x] Batch size `1` olacak — [[ADR-002 CNN Topolojisi ve Dataset]].
- [x] Ağırlık ve aktivasyonlar **simetrik signed INT8** olacak — [[ADR-003 INT8 Fixed-Point Formatı]].
- [x] Accumulator INT32 signed olacak — [[ADR-003 INT8 Fixed-Point Formatı]].
- [x] PS–PL veri hareketi AXI DMA ile, **Simple/Direct Register Mode** — [[ADR-007 DMA Modu]].
- [x] PL tarafında **tek clock domain** kullanılacak, 100 MHz — [[ADR-008 Clock Domain Stratejisi]].
- [x] Giriş ve çıkış AXI4-Stream olacak, **TDATA 64-bit** — [[ADR-006 AXI Stream Paket Semantiği]].
- [ ] Kontrol ve durum register'ları AXI4-Lite olacak.
- [x] İlk sürümde ağırlıklar BRAM/ROM içine önceden yüklenecek, **8 banka** — [[ADR-011 Ağırlık Bellek Adresleme]].
- [ ] Önce tek convolution katmanı, sonra tüm ağ çalıştırılacak.

### Stretch goal seçenekleri

- [ ] Doğrudan kamera girişi
- [ ] Birden fazla clock domain
- [ ] Scatter-gather veya cyclic DMA
- [ ] Çalışma zamanında ağırlık yükleme — ⚠️ **Aşama 3 (RFF) hedefleniyorsa stretch goal değil, önkoşul.** Aşama 2 başlarken karara bağla (`ADR-012`)
- [ ] Sparsity desteği
- [ ] Değişken görüntü boyutu
- [ ] Parametrik ağ/topoloji
- [ ] Enerji ölçümü
- [ ] Secure boot veya imzalı model paketi

> [!warning] Kapsam riski
> Kamera, tam CNN, dinamik ağırlık yükleme, çoklu clock ve sparsity aynı anda başlangıç kapsamına alınmamalıdır. Önce küçük fakat tamamen doğrulanmış bir uçtan uca sistem kurulmalıdır.

---

## 3. Sistem mimarisi

```text
PS / DDR
   │
   │ MM2S DMA
   ▼
AXI4-Stream Input
   │
   ▼
Input Buffer / Line Buffer
   │
   ▼
Window Generator / Data Mapper
   │
   ▼
Systolic Array / MAC Engine
   │
   ▼
Bias → Requantization → ReLU → Pooling
   │
   ▼
Output Buffer
   │
   │ S2MM DMA
   ▼
PS / DDR → Classification Decision
```

Kontrol düzlemi:

```text
PS ──AXI4-Lite──> CONTROL / CONFIG / STATUS / ERROR / PERF registers
PL ──Interrupt──> PS
```

### İlk entegrasyon topolojisi

CNN bağlanmadan önce şu sistem kurulmalıdır:

```text
DDR → MM2S DMA → AXI FIFO veya pass-through → S2MM DMA → DDR
```

Bu test başarıyla tamamlandıktan sonra pass-through yerine sırasıyla basit aritmetik kernel, tek CNN katmanı ve tam CNN bağlanmalıdır.

---

## 4. Dört referans modeli

Tek bir golden model yeterli değildir. Aşağıdaki doğrulama zinciri kurulmalıdır:

```text
PyTorch FP32 model
        ↓
Quantized PyTorch model
        ↓
Bit-accurate integer golden model
        ↓
RTL simulation
        ↓
FPGA hardware
```

### 4.1 FP32 PyTorch modeli

Bu model ağ mimarisinin ve doğruluk hedefinin referansıdır.

- [ ] Random seed sabitlenecek.
- [ ] Train/validation/test split kaydedilecek.
- [ ] Dataset sürümü kaydedilecek.
- [ ] Normalizasyon katsayıları kaydedilecek.
- [ ] Model checkpoint hash'i tutulacak.
- [ ] PyTorch ve bağımlılık sürümleri kaydedilecek.
- [ ] Accuracy ve confusion matrix üretilecek.

### 4.2 Quantized PyTorch modeli

Tercih edilen başlangıç formatı:

- Ağırlık: signed INT8
- Aktivasyon: signed INT8, simetrik
- Bias: INT32
- Accumulator: signed INT32, MAC + bias için wrap modulo `2^32`
- Katman başına scale
- Açık rounding ve saturation davranışı

QAT, özellikle CNN'lerde post-training quantization kaynaklı doğruluk kaybını azaltmak için kullanılabilir.

Kaynaklar:

- [PyTorch Quantization Recipe](https://docs.pytorch.org/tutorials/recipes/quantization.html)
- [Brevitas Getting Started](https://xilinx.github.io/brevitas/dev/getting_started.html)

### 4.3 Bit-accurate integer golden model

Bu model RTL'nin gerçek matematiğini bire bir uygulamalıdır:

- Signed/unsigned davranışı
- Her ara sinyalin bit genişliği
- Çarpım genişliği
- Accumulator genişliği
- Arithmetic shift
- Rounding yöntemi
- Accumulator'da wrap modulo `2^32`; saturation yalnız requant output'unda
- Zero-point ve scale
- Bias, ReLU ve pooling işlem sırası

Örnek matematik:

$$
acc = \operatorname{wrap32}\!\left(\sum_i x_i w_i + bias\right)
$$

$$
y = sat_{int8}\left(round\left(\frac{acc \times multiplier}{2^{shift}}\right)\right)
$$

> [!warning] Rounding ayrıntısı
> `round-half-up`, `round-away-from-zero` ve `round-to-nearest-even` aynı sonuçları üretmez. Python, PyTorch ve RTL aynı davranışı kullanmalıdır.

Her katman için saklanacak test vektörleri:

- [ ] Giriş tensörü
- [ ] Quantized ağırlıklar
- [ ] Bias değerleri
- [ ] Accumulator çıktısı
- [ ] Requantization çıktısı
- [ ] ReLU/pooling çıktısı
- [ ] Beklenen final sınıfı

### 4.4 RTL ve FPGA referansı

Karşılaştırmalar sadece final sınıf üzerinde yapılmamalıdır. Mümkünse her katmanın çıktısı veya katman çıktısının CRC/hash değeri alınmalıdır.

```text
FP32 ↔ Quantized model
Quantized model ↔ Integer golden model
Integer golden model ↔ RTL
RTL ↔ FPGA
```

---

## 5. RTL geliştirme sırası

Tam LeNet RTL'si bir anda geliştirilmemelidir.

### Aşama 1 — Aritmetik temel bloklar

- [ ] Parametrik signed multiplier
- [ ] Geniş accumulator
- [ ] INT32 wrapping accumulator
- [ ] Arithmetic shifter
- [ ] Rounding birimi
- [ ] Requantizer
- [ ] ReLU
- [ ] Max-pooling

### Aşama 2 — Systolic array

- [ ] Tek processing element
- [ ] 2×2 systolic array
- [ ] Parametrik `N×N` array
- [ ] Matrix multiplication testi
- [ ] Pipeline dolma/boşalma kontrolü
- [ ] Partial tile desteği
- [ ] PE utilization sayacı

### Aşama 3 — Görüntü veri yolu

- [ ] Line buffer
- [ ] Sliding-window generator
- [ ] Padding desteği
- [ ] Stride desteği
- [ ] Kanal ve kernel sayaçları
- [ ] Window–weight eşlemesi

### Aşama 4 — CNN katmanları

- [ ] Tek convolution katmanı
- [ ] Bias
- [ ] Requantization
- [ ] ReLU
- [ ] Pooling
- [ ] Fully connected katman
- [ ] Katman sıralayıcı/controller

### Aşama 5 — AXI shell

- [ ] AXI4-Stream slave girişi
- [ ] AXI4-Stream master çıkışı
- [ ] AXI4-Lite register arabirimi
- [ ] Interrupt
- [ ] Soft reset
- [ ] Error/status raporlama

### Mimari karar: `im2col` veya doğrudan convolution — karara bağlandı ([[ADR-005 Direct Convolution]])

**Doğrudan (streaming) convolution seçildi: line buffer + sliding-window generator. Görüntü hiçbir zaman `im2col` matrisi olarak DDR'ye açılmayacak.** `im2col` görüntüyü kernel boyutu katına şişirip DDR'ye yazıp geri okumayı gerektirir — DMA zaten bu sistemdeki asıl darboğaz ([[ADR-007 DMA Modu]]), im2col tam olarak o darboğazı büyütür.

Uygulama sırası:

1. Systolic array önce bağımsız GEMM olarak doğrulanır.
2. Görüntü hiçbir zaman `im2col` matrisi olarak DDR'ye yazılmaz.
3. PL içindeki window generator, systolic array'e tile/vektör üretir.
4. Fully connected katman aynı MAC altyapısını `kH=kW=1` özel durumu olarak yeniden kullanır.

---

## 6. Tasarım sözleşmeleri

### 6.1 System Requirements Specification — SRS

Ölçülebilir gereksinimler tanımlanmalıdır:

- Desteklenen görüntü boyutu
- Giriş formatı
- Sınıf sayısı
- Minimum accuracy
- FP32 modele göre izin verilen accuracy kaybı
- Minimum FPS
- Maksimum inference latency
- Clock hedefi
- LUT/FF/BRAM/DSP bütçesi
- Güç hedefi veya ölçüm yöntemi
- Reset sonrası toparlanma davranışı
- Hatalı frame davranışı

Örnek:

```text
REQ-PERF-001:
Sistem, 100 MHz PL clock altında batch=1 için en az X frame/s işleyecektir.

REQ-NUM-001:
RTL inference çıktısı, belirtilen test vektörlerinde integer golden model ile bit-exact eşleşecektir.
```

### 6.2 Interface Control Document — ICD

Tanımlanması gerekenler:

- `TDATA` genişliği
- Piksel paketleme sırası
- Endianness
- Signed/unsigned veri
- `TKEEP` kullanımı
- `TLAST` anlamı
- `TUSER` anlamı
- Frame boyutu
- Bozuk/eksik frame davranışı
- Backpressure davranışı
- Clock/reset ilişkisi

> [!success] Bu bölüm karara bağlandı — [[ADR-006 AXI Stream Paket Semantiği]]
> Aşağıdaki tablo artık örnek değil, **bağlayıcı sözleşmedir**.

```text
TDATA  = 64 bit (sabit)
TLAST  = frame'in sonu (tüm frame, tek descriptor)
TKEEP  = arayüzde mevcut, fonksiyonel olarak sabit all-1
TUSER  = kullanılmıyor
```

Video AXI4-Stream IP semantiği (`TUSER=start-of-frame`, `TLAST=end-of-line`) bu projede kullanılmıyor — video IP'ye entegrasyon yok, tek descriptor = tek tam frame modeli yeterli ve belirsizliksiz.

### 6.3 Numerical Specification

Her katman için tablo tutulmalıdır:

> [!success] Bu bölüm karara bağlandı — [[ADR-003 INT8 Fixed-Point Formatı]]
> Aşağıdaki tablo artık örnek değil, **bağlayıcı sözleşmedir**.

| Alan | Karar |
|---|---|
| Input | INT8 signed, simetrik (z=0), per-tensor ölçek |
| Weight | INT8 signed, simetrik (z=0), **per-output-channel** ölçek |
| Product | INT16 signed (exact) |
| Accumulator | INT32 signed; MAC + bias 32-bit wrap, accumulator saturation yok |
| Bias | INT32 signed, acc domain'inde, per-channel |
| M0 (çarpan) | `[2^16, 2^17)`, **signed register'da** tutulur |
| n (shift) | unsigned 6-bit (`0..63`), per-channel |
| Requant hesap yolu | signed 64-bit product + rounding offset + arithmetic shift |
| Requantization | `half_ulp = (n == 0 ? 0 : 2^(n-1))`; `y_raw = (acc·M0 + half_ulp) >>> n` |
| Rounding | **round-half-up** (nearest-even DEĞİL) |
| Saturation + ReLU | `clamp(lo, 127)`, `lo = 0` (ReLU'lu) / `-128` (ReLU'suz) |
| Signedness | Arithmetic operands ve intermediates `signed`; shift count `n` unsigned |

> [!warning] Verilog tuzağı
> Bir ifadedeki herhangi bir operand unsigned ise ifadenin tamamı unsigned olur ve `>>>`
> mantıksal kaydırmaya döner — negatif acc'de sonuç çöp çıkar. Python varsayılan olarak doğru,
> Verilog varsayılan olarak yanlış davranır.

> [!warning] Bit-exact'in kapsamı
> **PyTorch quantized model ile integer golden model bit-exact OLMAYACAK.** O karşılaştırma
> tolerans tabanlıdır. Bit-exact sözleşme yalnızca **integer golden ↔ RTL ↔ FPGA** zincirinde
> geçerlidir.

### 6.4 Clock and Reset Specification

- Tüm clock kaynakları ve frekansları
- Her modülün clock domain'i
- Clock ilişkileri
- Reset assertion/deassertion yöntemi
- CDC primitive'leri
- Timing constraint sorumluluğu
- Reset sırasında AXI davranışı
- FIFO'nun tek tarafı resetlenirse uygulanacak politika

### 6.5 Register Map

> [!success] Bu bölüm karara bağlandı — [[ADR-015 Register Map ve Parametre Yükleme]]
> Aşağıdaki liste artık yalnız *hangi* register'ların bulunacağını özetliyor. Offset, bit
> alanı, reset değeri, W1C davranışı ve **shadow + commit yükleme protokolü** ADR-015'te
> bağlayıcı olarak tanımlı.

Örnek register'lar:

| Register | İçerik |
|---|---|
| `CONTROL` | start, stop, soft reset |
| `STATUS` | idle, busy, done, error |
| `CONFIG` | görüntü/katman parametreleri |
| `ERROR` | protocol, frame, overflow, timeout |
| `VERSION` | RTL ve register-map sürümü |
| `CYCLE_COUNT` | toplam çalışma çevrimi |
| `STALL_IN` | input starvation çevrimi |
| `STALL_OUT` | output backpressure çevrimi |
| `FRAME_COUNT` | işlenen frame sayısı |

Her bit için belirtilmesi gerekenler:

- Offset
- Bit aralığı
- Reset değeri
- Read/write tipi
- Write-one-to-clear davranışı
- Donanım/yazılım yan etkisi

### 6.6 Verification Plan ve traceability

| Gereksinim | Doğrulama yöntemi | Test kimliği |
|---|---|---|
| Bit-exact convolution | Golden-model comparison | `T_NUM_CONV_001` |
| AXI backpressure güvenliği | Random stall + assertion | `T_AXI_BP_001` |
| 100 MHz çalışma | Post-route STA | `T_STA_001` |
| Accuracy hedefi | Tüm test dataset'i | `T_ML_ACC_001` |
| Reset recovery | Mid-frame reset | `T_RST_001` |
| Güvenli CDC | `report_cdc` | `T_CDC_001` |
| Requantizer bit-exact (pre-clamp `y_raw`) | Tie vector + golden karşılaştırma | `T_NUM_REQ_001` |
| Requantizer valid/ready + latency | SVA + random backpressure | `T_REQ_TIMING_001` |
| Parametre yükleme atomikliği | Eksik/geçersiz commit senaryoları | `T_REG_PARAM_001` |
| Byte lane ve `$readmemh` sırası | Bilinen desenli frame | `T_AXI_LANE_001` |
| Accumulator wrap ve taşma bayrağı | `2^31` sınırına oturtulmuş vektörler | `T_NUM_OVF_001` |

Her gereksinimin en az bir testi, her testin de en az bir gereksinimi olmalıdır.

---

## 7. AXI ve DMA entegrasyonu

### 7.1 Temel AXI handshake

Transfer koşulu:

```systemverilog
transfer = tvalid && tready;
```

Kurallar:

- Master, `TVALID=1` olduktan sonra handshake'e kadar `TVALID` değerini korumalıdır.
- `TVALID=1 && TREADY=0` iken `TDATA`, `TKEEP`, `TLAST` ve `TUSER` sabit kalmalıdır.
- Master, `TVALID` üretmek için `TREADY` beklememelidir.
- Sayaçlar ve FSM, veri tüketimini yalnızca handshake gerçekleştiğinde yapmalıdır.
- Input ve output backpressure güvenli biçimde taşınmalıdır.
- Interface girişinden çıkışına uzun combinational `TREADY` yolları oluşturulmamalıdır.

Kaynaklar:

- [Arm AMBA AXI ve ACE Protocol Specification](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)
- [Arm Introduction to AMBA AXI4](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Learn%20the%20Architecture/102202_0100_01_Introduction_to_AMBA_AXI.pdf)

### 7.2 Timing ve buffering

Gerektiğinde kullanılabilecek yapılar:

- AXI Register Slice
- Skid buffer
- Senkron FIFO
- Async FIFO
- AXI4-Stream Clock Converter
- AXI4-Stream Data Width Converter

Register slice ve skid buffer yalnızca timing için değil, output backpressure bir çevrim geç görüldüğünde veriyi korumak için de kullanılabilir.

Kaynak: [AMD AXI4-Stream Infrastructure — PG085](https://docs.amd.com/r/en-US/pg085-axi4stream-infrastructure)

### 7.3 DMA geliştirme sırası

1. DDR → MM2S → FIFO/pass-through → S2MM → DDR
2. Pass-through yerine `data + 1`
3. Küçük matrix kernel
4. Tek convolution katmanı
5. Tam CNN

### 7.4 DMA optimizasyonları

- Buffer adreslerini bus genişliğine hizalamak
- Yeterince uzun burst kullanmak
- Küçük transferlerden kaçınmak
- Ping-pong buffer kullanmak
- Hesaplama ve DMA transferini örtüştürmek
- Gereksiz frame başına interrupt yükünü azaltmak
- PS cache flush/invalidate gereksinimini açıkça tanımlamak
- Simple mode ile başlayıp yalnızca ihtiyaç varsa scatter-gather'a geçmek

Kaynak: [AMD AXI DMA Product Guide — PG021](https://docs.amd.com/r/en-US/pg021_axi_dma/Introduction)

---

## 8. CDC, RDC ve metastability

Metastability tamamen yok edilemez; olasılığı yeterince düşük bir MTBF seviyesine indirilir.

### 8.1 CDC karar tablosu

| Geçen bilgi | Kullanılacak yapı |
|---|---|
| Tek bitlik yavaş seviye | İki veya daha fazla FF / `xpm_cdc_single` |
| Tek çevrimlik pulse | Toggle, handshake veya `xpm_cdc_pulse` |
| Çok bitli kontrol kelimesi | Handshake ile sabit tutulan bus |
| Sürekli stream | Async FIFO |
| AXI4-Stream | AXIS Clock Converter/Data FIFO |
| Pointer/sayaç | Gray-coded crossing |
| Reset deassertion | Her domain içinde senkron |

### 8.2 Yasak veya riskli uygulamalar

- [ ] Multi-bit bus bitlerini ayrı ayrı iki FF'den geçirmek yok.
- [ ] Fast-to-slow pulse'u yalnızca iki FF ile geçirmek yok.
- [ ] FPGA fabric içinde logic-generated clock yok.
- [ ] CDC hatalarını düşünmeden `set_false_path` ile gizlemek yok.
- [ ] Gerekçesiz CDC waiver yok.
- [ ] Reset'i tüm domain'lerde kontrolsüz kaldırmak yok.

### 8.3 Reset yaklaşımı

Önerilen temel yaklaşım:

```text
Asynchronous assertion
Synchronous deassertion in each clock domain
```

Belirlenecek davranışlar:

- DMA çalışırken PL resetlenirse ne olur?
- Yarım frame atılır mı?
- FIFO'nun bir tarafı resetlenirse diğer taraf ne yapar?
- Reset sonrası `TVALID/TREADY` başlangıç değerleri nedir?
- PS timeout sonrası yeniden başlatma sırası nedir?

### 8.4 CDC geçiş kriteri

```text
Critical CDC       = 0
Unsafe CDC         = 0
Undocumented waiver = 0
Unconstrained path = 0
```

Kaynaklar:

- [AMD UG949 — Clock Domain Crossing](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Clock-Domain-Crossing)
- [AMD UG906 — Report Clock Domain Crossings](https://docs.amd.com/r/2023.1-English/ug906-vivado-design-analysis/Report-Clock-Domain-Crossings)
- [AMD UG903 — CDC Constraints](https://docs.amd.com/r/2024.1-English/ug903-vivado-using-constraints/About-CDC-Constraints)

---

## 9. Verification stratejisi

Öğrenci projesi için önerilen araç kombinasyonu:

- RTL lint: Verilator ve Vivado
- Unit/regression: cocotb + pytest
- Golden model: Python/NumPy
- AXI protocol checking: AMD AXI VIP
- Assertions: SystemVerilog Assertions
- CDC/timing: Vivado raporları
- Hardware debug: ILA
- Otomasyon: CI içinde lint + unit test + regression

### 9.1 Verification mimarisi

```text
Test / Sequence
      │
      ▼
Driver ──> DUT ──> Monitor
                    │
                    ▼
             Scoreboard
                    │
                    ▼
              Golden Model
```

Kavramlar:

- **Driver:** DUT girişlerini sürer.
- **Monitor:** Interface transferlerini pasif biçimde izler.
- **Scoreboard:** Beklenen ve gerçek çıktıyı karşılaştırır.
- **Reference model:** Beklenen matematiksel sonucu üretir.
- **Coverage:** Hangi durumların test edildiğini ölçer.
- **Assertion:** Her çevrimde sağlanması gereken protokol özelliklerini kontrol eder.

### 9.2 cocotb veya UVM kararı

Cocotb, Python ile RTL doğrulamasını ve PyTorch/NumPy golden model entegrasyonunu kolaylaştırır.

- [cocotb resmî dokümantasyonu](https://docs.cocotb.org/en/stable/)

UVM endüstriyel ve IEEE standardıdır; ancak sıfırdan başlayan ekipte tam UVM ortamı projenin ana hedefini gölgeleyebilir.

- [IEEE 1800.2 UVM Standardı](https://standards.ieee.org/ieee/1800.2/7567/)
- [Accellera Standards](https://accellera.com/downloads/standards)

> [!danger] Kritik kısıt — cocotb ile AXI VIP aynı simülatörde buluşmuyor
> **cocotb, Vivado XSim'i resmî olarak desteklemiyor** (yalnızca kısıtlı üçüncü taraf
> `cocotb-vivado`). **Icarus Verilog ise Vivado IP'lerini simüle edemiyor** — AXI VIP, AXI DMA,
> BRAM generator ve Zynq PS bloğu şifreli Xilinx IP'leridir. "cocotb + AXI VIP tek testbench"
> planı Hafta 8'de duvara çarpardı.

**Karar — iki katmanlı doğrulama ([[ADR-009 Doğrulama Ortamı]]):**

| Katman | Ortam | Kapsam |
|---|---|---|
| 1 | **cocotb + Icarus Verilog** | Kişi B'nin saf RTL'i: PE, requantizer, systolic array, line buffer, window generator, AXIS wrapper. Golden model karşılaştırmasının tamamı burada |
| 2 | **Vivado XSim + SystemVerilog TB** | AXI VIP, AXI DMA, BRAM generator, Zynq PS BFM. cocotb yok |

**Köprü — dosya tabanlı el sıkışma:** Golden model karşılaştırmasının simülatörün içinde canlı
olması gerekmiyor. Kişi A vektörleri dosyaya üretir → RTL `$readmemh` ile okur, çıktısını
dosyaya yazar → Python offline karşılaştırır. İki katman böyle ayrışır.

**UVM:** Kavramları öğrenilecek (driver, monitor, scoreboard, sequence, coverage — cocotb'de de
aynı yapıdır), tam UVM ortamı kurulmayacak. İki kişilik ekipte projenin ana hedefini gölgeler.

**Pratik sonuç:** Kişi B **iki testbench iskeleti** kuracak, bir değil — Hafta 6-7 iş yüküne
eklenmeli. CI'da yalnızca Katman 1 koşabilir (Icarus ücretsiz ve headless).

### 9.3 AXI VIP

- [AMD AXI Verification IP — PG267](https://docs.amd.com/r/en-US/pg267-axi-vip)
- [AMD AXI4-Stream Verification IP — PG277](https://docs.amd.com/v/u/en-US/pg277-axi4stream-vip)

---

## 10. Zorunlu testler

### 10.1 Unit testleri

- [ ] Sıfır giriş
- [ ] Minimum signed değer
- [ ] Maksimum signed değer
- [ ] Pozitif overflow
- [ ] Negatif overflow
- [ ] Saturation
- [ ] Negatif aktivasyon
- [ ] Tek elemanlı işlem
- [ ] Tam array boyutu
- [ ] Array boyutuna bölünmeyen matris
- [ ] Padding sınırları
- [ ] Farklı stride değerleri
- [ ] En az 100–1000 random seed

### 10.2 AXI4-Stream testleri

- [ ] `TREADY` sürekli `1`
- [ ] Rastgele backpressure
- [ ] Uzun süreli backpressure
- [ ] Arka arkaya frame
- [ ] Beat'ler arasında rastgele boşluk
- [ ] Partial `TKEEP`
- [ ] Erken `TLAST`
- [ ] Geç `TLAST`
- [ ] Eksik `TLAST`
- [ ] Frame ortasında reset
- [ ] Output stalled iken input gelmesi
- [ ] FIFO sınır koşulları

### 10.3 Numerik testler

- [ ] FP32 ve quantized accuracy karşılaştırması
- [ ] Quantized model ve integer golden karşılaştırması
- [ ] Her RTL katmanı için bit-exact karşılaştırma
- [ ] Tam ağ için bit-exact karşılaştırma
- [ ] FPGA ve RTL karşılaştırması
- [ ] Tüm test dataset'i üzerinde sınıflandırma
- [ ] Confusion matrix

### 10.4 Reset ve hata testleri

- [ ] Idle durumda reset
- [ ] Frame ortasında reset
- [ ] Backpressure sırasında reset
- [ ] Soft reset
- [ ] DMA timeout
- [ ] Hatalı frame sonrası toparlanma
- [ ] Interrupt clear/re-enable
- [ ] Overflow/underflow girişimi
- [ ] Beklenmeyen `TLAST`

### 10.5 Sistem testleri

- [ ] DMA loopback
- [ ] Accelerator bypass
- [ ] Tek frame
- [ ] Arka arkaya binlerce frame
- [ ] Farklı DMA buffer adresleri
- [ ] Cache flush/invalidate kontrolü
- [ ] Uzun süreli soak test
- [ ] Bitstream sonrası cold boot testi

### 10.6 Örnek SVA özelliği

```systemverilog
property axis_stable_during_stall;
  @(posedge aclk) disable iff (!aresetn)
    m_axis_tvalid && !m_axis_tready
    |=> m_axis_tvalid &&
        $stable(m_axis_tdata) &&
        $stable(m_axis_tkeep) &&
        $stable(m_axis_tlast) &&
        $stable(m_axis_tuser);
endproperty

assert property (axis_stable_during_stall);
```

Diğer assertion hedefleri:

- Kabul edilen veri = üretilen veri + içeride bekleyen veri
- FIFO overflow/underflow yok
- Frame başına doğru `TLAST` sayısı
- Illegal FSM state yok
- `start` sonrası belirli sürede `done` veya `error`
- Reset sonrası bilinen interface durumu

---

## 11. FPGA implementation ve timing closure

Her önemli aşamada çalıştırılacak raporlar:

- [ ] Synthesis DRC
- [ ] `report_methodology`
- [ ] `report_cdc`
- [ ] `report_clock_interaction`
- [ ] `report_timing_summary`
- [ ] `report_utilization`
- [ ] `report_power`
- [ ] Unconstrained path kontrolü

### Timing optimizasyon kontrol listesi

- [ ] DSP giriş/çıkış register'ları kullanılıyor mu?
- [ ] Uzun accumulator zincirleri pipeline edildi mi?
- [ ] BRAM çıkışları register'lı mı?
- [ ] `TREADY` yolu fazla uzun mu?
- [ ] Yüksek fanout reset/enable sinyalleri var mı?
- [ ] Büyük combinational mux yapıları var mı?
- [ ] Array boyunca fiziksel mesafe fazla mı?
- [ ] Gerekli register slice'lar eklendi mi?
- [ ] Synthesis sonrası kritik yollar RTL seviyesinde düzeltildi mi?

Hedefler:

```text
WNS >= 0
TNS = 0
Unconstrained paths = 0
Critical warnings = 0 veya yazılı olarak gerekçelendirilmiş
```

Kaynak: [AMD UltraFast Design Methodology — UG949](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Validating-at-Each-Design-Stage)

---

## 12. Performans ölçüm protokolü

Ölçüm kuralları sonuçlar görülmeden önce belirlenmelidir.

### 12.1 Donanım sayaçları

PL içine baştan eklenmesi önerilen sayaçlar:

- Toplam cycle
- Compute-active cycle
- Input starvation cycle
- Output backpressure cycle
- FIFO maksimum doluluk
- İşlenen frame sayısı
- Hatalı frame sayısı
- Timeout sayısı

### 12.2 Raporlanacak ölçütler

- FP32 accuracy
- INT8 accuracy
- RTL/FPGA accuracy
- Accuracy farkı
- Tek frame latency
- Ortalama latency
- P95/P99 latency
- Throughput — frame/s
- PL clock frekansı
- AXI/DMA bandwidth
- PE utilization
- LUT, FF, BRAM, DSP kullanımı
- Güç — ölçülebiliyorsa
- Enerji/inference — ölçülebiliyorsa

### 12.3 Karşılaştırma tablosu

| Platform | Accuracy | Latency | FPS | Güç | Enerji/inference |
|---|---:|---:|---:|---:|---:|
| PS CPU FP32 |  |  |  |  |  |
| PS CPU INT8 |  |  |  |  |  |
| PL Accelerator INT8 |  |  |  |  |  |

### 12.4 Benchmark disiplini

- Aynı dataset kullanılmalı.
- Aynı preprocessing uygulanmalı.
- Warm-up sayısı belirtilmeli.
- Ölçüm tekrar sayısı belirtilmeli.
- DMA süresinin latency'ye dahil olup olmadığı yazılmalı.
- Sadece kernel latency ile uçtan uca latency ayrı raporlanmalı.
- Bitstream, model ve commit kimlikleri sonuçla birlikte saklanmalı.

Kaynak: [MLPerf Tiny Benchmark](https://arxiv.org/abs/2106.07597)

---

## 13. 16 haftalık çalışma planı

| Hafta | Ana çıktı | Geçiş kriteri |
|---:|---|---|
| 1 | Board, dataset ve model kapsamı | Ölçülebilir hedefler donduruldu |
| 2 | ICD, arithmetic, clock/reset ve verification belgeleri | Ekip review tamamladı |
| 3 | FP32 PyTorch modeli | Eğitim yeniden üretilebilir |
| 4 | INT8 ve integer golden model | Quantized–integer eşleşmesi sağlandı |
| 5 | PE, accumulator ve requantizer | Unit testleri geçiyor |
| 6 | Küçük systolic array | Matrix testleri bit-exact geçiyor |
| 7 | Parametrik array ve tiling | Partial tile testleri geçiyor |
| 8 | Line buffer ve convolution | Golden model ile eşleşiyor |
| 9 | ReLU, pooling ve FC | Katman testleri geçiyor |
| 10 | AXI Stream wrapper | Random backpressure testleri geçiyor |
| 11 | DMA loopback ve PS yazılımı | DDR round-trip bit-exact |
| 12 | Tek CNN katmanı FPGA üzerinde | RTL–FPGA eşleşmesi var |
| 13 | Tam ağ FPGA üzerinde | Test vektörleri bit-exact |
| 14 | Timing/CDC/DRC closure | Kritik ihlal yok |
| 15 | Accuracy ve performans ölçümleri | Benchmark tekrarlanabilir |
| 16 | Regression ve rapor | Definition of Done tamamlandı |

### İlk iki haftanın ayrıntılı görevleri

#### 1. hafta

- [x] FPGA kartı ve part numarası kesinleştirilecek — PYNQ-Z2, `xc7z020clg400-1`.
- [x] Kullanılabilir Vivado/Vitis sürümü sabitlenecek — **Vivado 2024.1 + PYNQ v3.1** ([[ADR-001 Board ve Araç Sürümü]]).
- [x] Dataset seçilecek — böcek türü sınıflandırması ([[ADR-002 CNN Topolojisi ve Dataset]]).
- [x] CNN katmanları ve tensor boyutları çıkarıldı (Aşama 1 LeNet-5 reference model,
  5×5 valid convolution, girdi 32×32 RGB → `c_in=3`) — [[ADR-002 CNN Topolojisi ve Dataset]].
- [ ] FP32 CPU baseline ölçülecek.
- [ ] Kaynak ve performans hedefleri belirlenecek.
- [x] Git deposu kurulacak — **ProjectPriv** (private), GitHub'a push edildi.
- [ ] Issue sistemi kurulacak.

#### 2. hafta

- [x] Interface Control Document yazılacak — [[ADR-006 AXI Stream Paket Semantiği]] (§6.2).
- [x] Numerical Specification yazılacak — [[ADR-003 INT8 Fixed-Point Formatı]].
- [x] Clock/Reset Architecture yazılacak — tek domain 100 MHz ([[ADR-008 Clock Domain Stratejisi]]).
- [ ] Register map taslağı hazırlanacak.
- [ ] Verification Plan hazırlanacak.
- [ ] DMA loopback için küçük Vivado tasarımı kurulacak.
- [ ] 2×2 systolic array için ilk cocotb testi yazılacak.

---

## 14. Takım iş bölümü

Ekip 2 kişi. Dört sorumluluk alanı ikisi arasında bölünüyor:

1. ML, quantization ve golden model — **Kişi A**
2. Datapath, PE ve systolic array — **Kişi B**
3. AXI/DMA, PS yazılımı ve Vivado entegrasyonu — **Kişi B**
4. Verification, CI, CDC ve performans analizi — **Kişi B** (Katman 1/2 testbench'leri), **Kişi A** (golden model tarafı)

Kurallar:

- Her arayüzün bir yazarı ve farklı bir reviewer'ı olmalı.
- Haftalık entegrasyon yapılmalı.
- Uzun süre ayrı geliştirilip dönem sonunda ilk kez birleşilmemeli.
- Interface değişiklikleri ADR ile kayıt altına alınmalı.
- Başarısız test kapatılmadan yeni özellik eklenmemeli.

---

## 15. Önerilen depo yapısı

```text
project/
├── README.md
├── docs/
│   ├── requirements.md
│   ├── interface-control.md
│   ├── numerical-spec.md
│   ├── clock-reset-architecture.md
│   ├── register-map.md
│   ├── verification-plan.md
│   ├── benchmark-protocol.md
│   └── adr/
├── model/
│   ├── train/
│   ├── quantize/
│   ├── export/
│   ├── golden/
│   └── checkpoints/
├── rtl/
│   ├── arithmetic/
│   ├── pe/
│   ├── systolic_array/
│   ├── line_buffer/
│   ├── convolution/
│   ├── pooling/
│   ├── quantization/
│   ├── axis/
│   └── top/
├── verification/
│   ├── unit/
│   ├── axis/
│   ├── integration/
│   ├── assertions/
│   ├── vectors/
│   └── regression/
├── soc/
│   ├── vivado/
│   ├── constraints/
│   ├── tcl/
│   └── block_design/
├── software/
│   ├── baremetal/
│   └── linux/
├── scripts/
├── results/
│   ├── timing/
│   ├── utilization/
│   ├── power/
│   ├── accuracy/
│   └── performance/
└── .github/ veya ci/
```

Üretilmiş Vivado dosyalarının tamamını Git'e eklemek yerine projeyi Tcl ile tekrar kurabilmek tercih edilmelidir. Kullanılan Vivado sürümü sabitlenmelidir.

---

## 16. Okuma listesi

### Öncelik 1 — Mutlaka okunmalı

1. [Gradient-Based Learning Applied to Document Recognition — LeNet-5](https://yann.lecun.com/exdb/publis/)
2. [Efficient Processing of Deep Neural Networks: A Tutorial and Survey](https://arxiv.org/abs/1703.09039)
3. [Eyeriss: A Spatial Architecture for Energy-Efficient Dataflow](https://eems.mit.edu/wp-content/uploads/2016/04/eyeriss_isca_2016.pdf)
4. [In-Datacenter Performance Analysis of a Tensor Processing Unit](https://research.google/pubs/in-datacenter-performance-analysis-of-a-tensor-processing-unit/)
5. [FINN: Fast, Scalable Binarized Neural Network Inference](https://arxiv.org/abs/1612.07119)
6. [MLPerf Tiny Benchmark](https://arxiv.org/abs/2106.07597)

### Öncelik 2 — Mimari derinlik

- [Eyeriss Project ve yayınları](https://eyeriss.mit.edu/)
- [FINN Publications](https://xilinx.github.io/finn/publications.html)
- [Open-source FPGA–ML Co-design for MLPerf Tiny](https://arxiv.org/abs/2206.11791)
- [AMD FINN GitHub](https://github.com/Xilinx/finn)
- [AMD Brevitas](https://github.com/Xilinx/brevitas)

### Öncelik 3 — Protokol ve implementation

- [Arm AMBA AXI Specification](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)
- [AMD AXI DMA PG021](https://docs.amd.com/r/en-US/pg021_axi_dma/Introduction)
- [AMD AXI4-Stream Infrastructure PG085](https://docs.amd.com/r/en-US/pg085-axi4stream-infrastructure)
- [AMD IP Integrator UG994](https://docs.amd.com/r/en-US/ug994-vivado-ip-subsystems/Common-Internal-Bus-Interfaces)
- [AMD IP Integrator Tutorial UG995](https://docs.amd.com/r/2024.1-English/ug995-vivado-ip-subsystems-tutorial/Step-2-Creating-an-IP-Integrator-Design)
- [AMD CDC Analysis UG906](https://docs.amd.com/r/2023.1-English/ug906-vivado-design-analysis/Report-Clock-Domain-Crossings)
- [AMD Constraints UG903](https://docs.amd.com/r/2024.1-English/ug903-vivado-using-constraints/About-CDC-Constraints)
- [AMD UltraFast Methodology UG949](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology/Validating-at-Each-Design-Stage)

---

## 17. Ders ve eğitim serileri

Önerilen takip sırası:

### 17.1 Dijital tasarım ve FPGA temeli

- [MIT 6.111 — Introductory Digital Systems Laboratory](https://ocw.mit.edu/courses/6-111-introductory-digital-systems-laboratory-spring-2006/)

Odak konuları:

- Sequential logic
- FSM
- Timing
- Synchronization
- FPGA tasarım pratiği

### 17.2 Efficient ML ve TinyML

- [MIT 6.S965 — TinyML and Efficient Deep Learning](https://www.aihardware.mit.edu/tinyml-and-efficient-deep-learning-course-6-s965/)

Odak konuları:

- MAC/FLOP ve efficiency metrics
- Quantization
- Pruning
- Model compression
- Edge deployment

### 17.3 AXI

- [Arm Introduction to AMBA AXI4](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/Learn%20the%20Architecture/102202_0100_01_Introduction_to_AMBA_AXI.pdf)
- [Arm AMBA AXI Protocol Specification](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)

Öğrenme sırası:

1. VALID/READY
2. AXI4-Stream
3. AXI4-Lite
4. AXI4 memory-mapped channels
5. Burst, outstanding transaction ve ordering

### 17.4 Vivado SoC entegrasyonu

- [AMD UG995 — IP Integrator Tutorial](https://docs.amd.com/r/2024.1-English/ug995-vivado-ip-subsystems-tutorial/Step-2-Creating-an-IP-Integrator-Design)
- [AMD PG021 — AXI DMA](https://docs.amd.com/r/en-US/pg021_axi_dma/Introduction)
- [AMD PG085 — AXI4-Stream Infrastructure](https://docs.amd.com/r/en-US/pg085-axi4stream-infrastructure)

### 17.5 Verification

- [cocotb Documentation](https://docs.cocotb.org/en/stable/)
- [Verilator Documentation](https://verilator.org/guide/latest/)
- [AMD AXI VIP PG267](https://docs.amd.com/r/en-US/pg267-axi-vip)
- [AMD AXI4-Stream VIP PG277](https://docs.amd.com/v/u/en-US/pg277-axi4stream-vip)
- [Accellera UVM Resources](https://accellera.com/downloads/standards)

---

## 18. Definition of Done

Proje aşağıdaki maddeler sağlanmadan tamamlanmış sayılmamalıdır:

### Model ve matematik

- [ ] Model eğitimi sabit seed ile yeniden üretilebiliyor.
- [ ] Dataset ve preprocessing sürümlenmiş.
- [ ] Ağırlık dosyasının hash'i kayıtlı.
- [ ] Quantization parametreleri kayıtlı.
- [ ] Integer golden model mevcut.
- [ ] RTL, integer golden modelle bit-exact eşleşiyor.
- [ ] FPGA, RTL ile eşleşiyor.

### Interface ve protokol

- [ ] AXI interface sözleşmesi yazılı.
- [ ] Randomized backpressure testleri geçiyor.
- [ ] AXI VIP protokol ihlali göstermiyor.
- [ ] Reset ve hata toparlanması doğrulanmış.
- [ ] Buffer ownership ve cache protokolü yazılı.

### CDC, timing ve kaynak

- [ ] Açıklamasız CDC/RDC problemi yok.
- [ ] Unconstrained timing path yok.
- [ ] Post-route `WNS >= 0`.
- [ ] Kaynak kullanımı bütçe içinde.
- [ ] Critical warning yok veya gerekçeli.

### Sistem ve ölçüm

- [ ] Test dataset'i üzerinde accuracy raporlanmış.
- [ ] Latency ve FPS raporlanmış.
- [ ] DMA dahil ve hariç latency ayrılmış.
- [ ] CPU ve accelerator karşılaştırması yapılmış.
- [ ] Uzun süreli test tamamlanmış.
- [ ] Sonuçlar bitstream, model ve commit ile ilişkilendirilmiş.

### Tekrar üretilebilirlik

- [ ] Temiz ortamda build prosedürü dokümante.
- [ ] Vivado/Vitis sürümü belirtilmiş.
- [ ] Simülasyon tek komutla veya belgelenmiş komutla çalışıyor.
- [ ] Regression sonucu makine tarafından okunabilir formatta üretiliyor.
- [ ] Kullanılmayan veya başarısız deneyler de kayıt altında.

---

## 19. Risk listesi

| Risk | Etki | Erken önlem |
|---|---|---|
| Kapsamın fazla geniş olması | Projenin tamamlanmaması | MVP ve stretch goal ayrımı |
| Golden model ile RTL rounding farkı | Sürekli numerik hata | ✅ Numerical spec kilitlendi ([[ADR-003 INT8 Fixed-Point Formatı]]); ilk test `T_NUM_REQ_001` **tie vektörleriyle** — rastgele test tie'ı kaçırır |
| AXI backpressure hatası | Veri kaybı/deadlock | Random stall, SVA ve VIP |
| BRAM bant genişliği yetersizliği | Düşük PE utilization | Banking ve erken bandwidth modeli |
| Timing closure başarısızlığı | Düşük clock veya başarısız bitstream | Erken synthesis ve pipeline |
| CDC hatası | Rastgele donanım arızası | ✅ Tek clock domain kararlaştırıldı ([[ADR-008 Clock Domain Stratejisi]]) — PL içinde CDC yok |
| DMA/cache tutarsızlığı | Eski/yanlış veri | Buffer ownership ve cache protokolü |
| Araç sürümü farkı | Tekrar üretilemeyen build | ✅ Sürüm sabitlendi ([[ADR-001 Board ve Araç Sürümü]]); Tcl build hâlâ yapılacak |
| Ekiplerin geç entegrasyonu | Dönem sonunda büyük hata | Haftalık entegrasyon |
| Yalnızca final class testi | Gizli arithmetic hata | Katman bazlı bit-exact karşılaştırma |

---

## 20. Karar kayıtları

Mimari kararlar için kısa ADR notları tutulmalıdır.

### ADR şablonu

```markdown
# ADR-XXX: Karar başlığı

## Durum
Önerildi / Kabul edildi / Değiştirildi

## Bağlam
Hangi problemi çözüyoruz?

## Karar
Neyi seçtik?

## Alternatifler
Başka hangi seçenekleri değerlendirdik?

## Gerekçe
Bu seçimi neden yaptık?

## Sonuçlar
Performans, kaynak, doğrulama ve entegrasyon etkileri nelerdir?
```

İlk ADR adayları:

- [x] `ADR-001`: FPGA kartı ve Vivado sürümü -> [[ADR-001 Board ve Araç Sürümü]] -- PYNQ-Z2 (xc7z020clg400-1), Vivado 2024.1 + PYNQ v3.1, 2026-08-28
- [x] `ADR-002`: CNN topolojisi ve dataset -> [[ADR-002 CNN Topolojisi ve Dataset]] -- LeNet-5, INT8, 10 sinif, 32x32 RGB, 2026-08-28
- [x] `ADR-003`: INT8 quantization formatı -> [[ADR-003 INT8 Fixed-Point Formatı]] -- simetrik INT8, per-channel M0+shift, round-half-up, 2026-08-28
- [x] `ADR-004`: Systolic array boyutu → [[ADR-004 Systolic Array Boyutu]] — 8×8 (64 PE) kabul edildi, 2026-08-28
- [x] `ADR-005`: Direct convolution veya `im2col` -> [[ADR-005 Direct Convolution]] -- doğrudan streaming convolution (line buffer + window generator), 2026-08-28
- [x] `ADR-006`: AXI Stream packet semantiği → [[ADR-006 AXI Stream Paket Semantiği]] — TDATA=64bit, TLAST=frame sonu, TUSER kullanılmıyor, 2026-08-28
- [x] `ADR-007`: Simple DMA veya scatter-gather → [[ADR-007 DMA Modu]] — Simple/Direct Register Mode, 2026-08-28
- [x] `ADR-008`: Tek clock veya çoklu clock → [[ADR-008 Clock Domain Stratejisi]] — tek domain, FCLK0 @ 100MHz, 2026-08-28
- [x] `ADR-009`: cocotb veya UVM doğrulama ortamı -> [[ADR-009 Doğrulama Ortamı]] -- iki katmanlı: cocotb+Icarus (birim) / XSim+SV (sistem), 2026-08-28
- [x] `ADR-010`: Ağırlıkların BRAM veya DDR'de tutulması → BRAM/ROM, bkz. [[ADR-011 Ağırlık Bellek Adresleme]]
- [x] `ADR-011`: Ağırlık bellek düzeni/adresleme şeması → [[ADR-011 Ağırlık Bellek Adresleme]] — PyTorch native layout + 8 banka (c_out mod 8), 2026-08-28
- [ ] `ADR-012`: **Çalışma zamanında ağırlık yükleme** — ⚠️ AŞAMA 2 BAŞLARKEN KARARA BAĞLA.
  Şu an ağırlıklar bitstream'e gömülü ([[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]), yani ağ
  değiştirmek bitstream yenilemek demek. Aşama 3'te (RFF) ağ yapısı değişecekse bu stretch
  goal değil, önkoşul. Bkz. [[Kontrat Değerlendirmesi]]
- [ ] `ADR-013`: **Skip connection / residual toplama desteği** — ResNet ailesi bir ağ
  seçilirse datapath'e (conv → bias → requant → ReLU → pool) tensör toplama eklenmeli.
  En geç Aşama 2 sonunda netleşmeli
- [~] `ADR-014`: Requantizer port ve zamanlama sözleşmesi →
  [[ADR-014 Requantizer Port ve Zamanlama Sözleşmesi]] — sabit `LAT`, skid buffer, `k_last`
  kapısı, `out_y_raw`. **Önerildi, Kişi B onayı bekliyor**, 2026-09-25
- [~] `ADR-015`: Register map ve parametre yükleme protokolü →
  [[ADR-015 Register Map ve Parametre Yükleme]] — shadow + commit, `ERR_CFG_M0` zorunlu,
  `PARAM_SRC` mux. **Önerildi, Kişi B onayı bekliyor**, 2026-09-25
- [~] `ADR-016`: Aktivasyon tensör düzeni ve byte yerleşimi →
  [[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi]] — HWC, little-endian lane haritası,
  kanal dolgusu, çıkış payload'ı. **Önerildi, Kişi B onayı bekliyor**, 2026-09-25

---

## Hızlı başlangıç kontrol listesi

- [x] Kart ve FPGA part numarasını kesinleştir — PYNQ-Z2, `xc7z020clg400-1` ([[ADR-001 Board ve Araç Sürümü]]).
- [x] Vivado/Vitis sürümünü kesinleştir — Vivado 2024.1 + PYNQ v3.1 ([[ADR-001 Board ve Araç Sürümü]]).
- [ ] Repo ve klasör yapısını oluştur.
- [ ] Ölçülebilir gereksinimleri yaz.
- [x] LeNet tensor boyutlarını tabloya dök — [[ADR-002 CNN Topolojisi ve Dataset]].
- [ ] FP32 PyTorch baseline oluştur.
- [ ] INT8 numerical contract hazırla.
- [ ] Integer golden model yaz.
- [ ] 2×2 systolic array geliştir.
- [ ] cocotb scoreboard oluştur.
- [ ] AXI DMA loopback kur.
- [ ] AXI pass-through IP'yi backpressure altında doğrula.
- [ ] Tek convolution katmanını entegre et.
- [ ] Timing ve CDC raporlarını erken çalıştır.
- [ ] Her hafta uçtan uca regression çalıştır.

> [!summary] Son ilke
> Önce sözleşme, sonra golden model, sonra küçük RTL blokları, sonra AXI/DMA entegrasyonu, en son tam ağ. Her aşama ölçülebilir bir geçiş kriteriyle kapanmalıdır.
