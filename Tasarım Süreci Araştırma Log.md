---
title: Tasarım Süreci Araştırma Log
created: 2026-08-31
type: research
status: RTL kickoff öncesi son kontrol
tags: [dnn-accelerator, research, methodology, verification, block-design]
---

# Tasarım Süreci Araştırma Log

RTL yazımına resmen başlamadan önce dört alanda yapılan araştırmanın çıktısı: referans repo'lardaki block design bağlantı desenleri, sektör-standardı RTL tasarım metodolojisi, doğrulama/kontrol edilebilirlik pratiği, ve test aşaması değerlendirmesi. Her bulgu somut bir kaynağa bağlı ve mümkün olduğunda ilgili ADR'ye çapraz referans veriyor.

---

## 1. Referans Repo'lar — Block Design / Bağlantı Desenleri

Amaç: Kişi B'nin gerçek PYNQ-Z2 Vivado Block Design'ını kurarken bakabileceği somut örnekler,
"burada nasıl bağlanmış" seviyesinde.

### 1.1 [asirenius/cnn-accelerator](https://github.com/asirenius/cnn-accelerator) — en yakın ölçek eşleşmesi

Bu proje ölçek olarak bizimkine en yakın örnek: Zynq-7000 sınıfı, AXI4-Stream + AXI DMA ile
PS↔PL veri taşıma, AXI4-Lite ile kontrol, DSP tabanlı pipeline'lı convolution engine, bit-exact
referans model ile doğrulama.

**Klasör yapısı:**
```
cnn-accelerator/
├── hw/
│   ├── constraints/   # pin/timing constraint'leri
│   ├── model/         # referans (golden) model
│   ├── rtl/           # Verilog/VHDL modülleri
│   └── tb/            # simülasyon testbench'leri
├── sw/
│   ├── common/, cnn/, hal/, utils/   # HAL katmanı + performans ölçümü
├── scripts/
└── media/
```

**Bizim projeyle örtüşen noktalar:**
- AXI4-Stream + DMA veri yolu, AXI4-Lite kontrol yolu — birebir [[ADR-006 AXI Stream Paket Semantiği|ADR-006]] / [[ADR-007 DMA Modu|ADR-007]] ile aynı ayrım.
- "sw/hal" katmanı bizim Roadmap §15'teki `software/` klasörünün karşılığı — HAL'i erken ayrı bir katman olarak tutmak, PYNQ Python driver'ının (ADR-007'nin gerekçesi) üstüne net bir soyutlama koyuyor.
- `hw/model/` (golden model) ile `hw/rtl/` ayrı klasörler — bizim `model/golden/` ve `rtl/` ayrımıyla (Roadmap §15) aynı prensip: golden model asla RTL klasörüne karışmıyor.

**Fark/uyarı:** Bu repo `hw/tb/` altında tek bir testbench katmanı kullanıyor (muhtemelen tek simülatör). Bizim [[ADR-009 Doğrulama Ortamı|ADR-009]]'daki iki katmanlı (cocotb+Icarus / XSim+SV) ayrımı daha disiplinli — bu projenin tek-katman yaklaşımı küçük ölçekte işe yarıyor olabilir ama Xilinx IP (AXI VIP, DMA IP) içeren sistem testleri için cocotb'nin XSim desteklemediği gerçeğiyle er ya da geç karşılaşacaktır. Bizim ADR-009'un çakışma analizi bu riski baştan gördüğü için bir adım önde.

### 1.2 [rickyrorton/Systolic-array](https://github.com/rickyrorton/Systolic-array) — INT8 systolic + AXI4-Stream wrapper, en yakın mimari ölçek

4×4 INT8 systolic array, doğrudan bizim 8×8'imizin küçük kardeşi.

**Modül hiyerarşisi:**
```
AXI4_Stream_wrapper.v      # üst seviye AXI4-Stream arayüzü
  └─ systolic_data_setup.v # gelen veriyi input/weight buffer'lara yönlendirir
       ├─ input_buffer.v
       ├─ weight_buffer.v
       └─ systolic_array.v
            └─ int8mac.v   # tek PE, INT8 MAC birimi
  └─ normalizer.v          # çıktı normalizasyonu
  └─ output_buffer.v
sys_tb.v                   # testbench
```

**Bizim projeye uygulanabilir desen:** `AXI4_Stream_wrapper.v`'nin array'in kendisinden tamamen
ayrı bir modül olması — array saf sayısal bir blok, AXI protokolüyle hiç ilgilenmiyor. Bu birebir
bizim [[ADR-005 Direct Convolution|ADR-005]]'in "systolic array önce bağımsız GEMM olarak
doğrulanır, sonra window generator ile beslenir" sırasıyla ve [[ADR-009 Doğrulama Ortamı|ADR-009]]'un
"Kişi B'nin yazdığı, Xilinx IP içermeyen her şey Katman 1'de" ayrımıyla aynı prensibi teyit ediyor:
**AXI wrapper'ı array'in İÇİNE gömme, ayrı bir katman olarak dışına sar.** `normalizer.v`'nin
ayrı bir modül olması da bizim requantizer'ı (ADR-003) array'den bağımsız test edilebilir bir blok
olarak tutma kararımızı (T_NUM_REQ_001'in array'den önce yazılabilir olması) doğruluyor.

### 1.3 [NVDLA (nvdla/hw)](https://github.com/nvdla/hw) — büyük ölçek, bus-adapter ayrımı

NVDLA'nın Verilog modeli dört arayüze sahip: bir slave host arayüzü, bir interrupt hattı, ve
internal/external memory erişimi için iki master arayüz. Host ve memory arayüzleri **harici bus
adaptörleri** gerektiriyor — AXI4 ve TileLink için örnek adaptörler ayrı olarak dağıtılıyor
(kaynak: [nvdla.org integration guide](http://nvdla.org/hw/v1/integration_guide.html)).

**Ders:** NVDLA, çekirdek hesaplama mantığını protokolden tamamen ayırıp AXI'yi "takılabilir bir
adaptör" olarak dışarıda tutuyor. Bizim ölçeğimizde bu kadar ayrıştırmaya gerek yok (tek board,
tek protokol), ama prensip aynı: `systolic_array.v` / `requantizer.v` gibi çekirdek modüller
**hiçbir AXI sinyali görmemeli**, AXI yalnızca en dıştaki wrapper'da yaşamalı. Bu, zaten
[[ADR-004 Systolic Array Boyutu|ADR-004]] ve [[ADR-009 Doğrulama Ortamı|ADR-009]]'un ima ettiği
ayrımı büyük ölçekli bir üretim tasarımıyla doğruluyor.

### 1.4 [Gemmini](https://github.com/ucb-bar/gemmini) — kontrast örneği (farklı veri yolu)

Gemmini bir RoCC accelerator (RISC-V custom instruction), AXI değil. Sistem veri yoluna (System
Bus) doğrudan bağlanıyor, ayrı bir DMA motoru scratchpad ile ana bellek arasında veri taşıyor.
**Bize doğrudan bağlantı deseni vermiyor** (farklı bus paradigması) ama mimari olarak yararlı bir
kontrast: "execute" (systolic array) ile "load/store" (DMA) kontrolcülerini ayrı tutmaları, bizim
AXI-Stream girişi/çıkışını ayrı FSM'lerle sürme kararımızla (Roadmap §5 Aşama 5: AXI4-Stream slave
girişi ve master çıkışı ayrı maddeler) aynı prensibi paylaşıyor.

### 1.5 [alexforencich/verilog-axi](https://github.com/alexforencich/verilog-axi) / [verilog-axis](https://github.com/alexforencich/verilog-axis) — isimlendirme ve parametrizasyon referansı

Yaygın kullanılan, iyi belgelenmiş bir AXI/AXI-Stream bileşen kütüphanesi. Doğrudan kod
kopyalamıyoruz (kendi AXI4-Stream wrapper'ımızı ADR-006/007'ye göre kendimiz yazacağız) ama
**isimlendirme kuralı olarak referans değerli**:
- Modül dosya adları: `axi_*.v` (memory-mapped), `axil_*.v` (lite). Bizim de AXI4-Lite register
  arayüzü (Roadmap §5 Aşama 5) ile AXI4-Stream veri yolunu dosya adında bu şekilde ayırmamız,
  Vivado IP paketleyicisinin arayüzleri doğru çıkarması için de faydalı (bkz. §2.3 aşağıda).
- Parametre adları: `ADDR_WIDTH`, `DATA_WIDTH`, `STRB_WIDTH`, `ID_WIDTH` — bizim `TDATA=64-bit`
  sabit kararımızla (ADR-006) çelişmiyor, ama modülü yine de parametrik yazmak (sabit sayı yerine
  `parameter DATA_WIDTH = 64`) ileride RFF'ye (Aşama 3, [[Kontrat Değerlendirmesi]]) geçişte
  frame boyutu değişirse maliyetsiz esneklik sağlar.
- `tb/` altında cocotb kullanıyorlar — [[ADR-009 Doğrulama Ortamı|ADR-009]]'un Katman 1 seçimiyle
  aynı ekosistem, yani cocotb testbench yazarken bu repodaki testler doğrudan üslup referansı
  olabilir.

---

## 2. Sektör Standardı RTL Tasarım Metodolojisi

Kaynak: [AMD/Xilinx UltraFast Design Methodology Guide — UG949](https://docs.amd.com/r/2022.1-English/ug949-vivado-design-methodology/About-the-UltraFast-Design-Methodology),
[UG1118 — Creating and Packaging Custom IP](https://www.xilinx.com/support/documents/sw_manuals/xilinx2022_2/ug1118-vivado-creating-packaging-custom-ip.pdf).

### 2.1 Bu projenin ADR-driven kontrat yaklaşımı UG949 ile örtüşüyor mü?

**Evet, doğrudan örtüşüyor.** UG949'un ana ilkesi: erken aşamalar (RTL tanımı, arayüz sözleşmesi)
sonraki aşamalardan (implementation, timing closure) çok daha yüksek etkiye sahip; "timing
kapanmıyorsa implementation'da debug etmek yerine synthesis/RTL/constraint'lere geri dön." Bizim
zaten yaptığımız şey tam olarak bu: RTL'ye hiç dokunmadan önce 10 ADR ile numerik format, dataflow,
AXI semantiği, DMA modu, clock stratejisi ve doğrulama ortamını kilitledik. Bu, UG949'un
"validation should occur before synthesis in the elaborated RTL design" ilkesinin bir üst
seviyedeki (mimari sözleşme seviyesinde) karşılığı.

### 2.2 Somut RTL kodlama pratikleri (UG949, doğrudan uygulanabilir)

- **I/O ve clock elemanlarını üst seviyeye yakın tut** — bizim AXI4-Stream wrapper'ın en dışta
  olması kararıyla (bkz. §1.2) zaten örtüşüyor.
- **Modül sınırlarında veri register'la** — pipeline'lanabilirlik ve timing için. Bizim
  [[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün "requant yolundaki tüm sinyaller signed,
  requant hesap yolu signed 64-bit" maddesi zaten pipeline register'ları gerektirecek kadar derin bir yol —
  bu register'ların modül sınırında (requantizer girişi/çıkışı) olması timing için önemli,
  ADR-003'te bu netleştirilmemiş, RTL yazarken eklenmeli.
- **Reset stratejisi:** UG949 hem senkron hem asenkron reset örnekleri veriyor, "HDL'de reset'i
  tamamen elemeye çalışma" diyor. Bizim [[ADR-008 Clock Domain Stratejisi|ADR-008]] zaten
  "async-assert/sync-deassert tek domain içinde" diyor — bu UG949'un önerdiği standart deseni
  birebir uyguluyor.
- **Clock enable, clock gating değil:** Kaynak saati kapatmak yerine clock enable kullanmak
  öneriliyor. Bizim tasarımda FSM'lerin `valid`/`ready` bazlı ilerlemesi zaten bu deseni doğal
  olarak üretiyor (AXI handshake = clock enable mantığı), ekstra bir aksiyon gerekmiyor.
- **Control set minimizasyonu:** Çok sayıda farklı reset/enable kombinasyonu kaynak israfına yol
  açar. 8 banka ağırlık belleği ([[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]) ve 8 requantizer
  ([[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]) gibi tekrarlayan yapılarda **hepsinin aynı
  reset/enable sinyalini paylaşması** gerekiyor — ayrı ayrı kontrol sinyali icat edilmemeli.
- **UltraFast Design Methodology Checklist (XTP301):** Xilinx'in resmi kontrol listesi mevcut,
  synthesis öncesi/sonrası RTL DRC'leri çalıştırmayı içeriyor — Vivado'da `report_methodology`
  komutu zaten Roadmap §11'de listeli, bu checklist'in kısmi karşılığı orada var.

### 2.3 AXI4-Stream custom IP paketleme — isimlendirme kuralı zorunlu

Kaynak: [UG1118 — Inferring AXI Signals](https://docs.amd.com/r/2025.1-English/ug1118-vivado-creating-packaging-custom-ip/Inferring-AXI-Signals).

Vivado'nun IP paketleyicisinin AXI4-Stream arayüzünü **otomatik çıkarabilmesi** için port adlarının
`<arayüz_adı>_tdata`, `<arayüz_adı>_tvalid`, `<arayüz_adı>_tready`, `<arayüz_adı>_tlast`,
`<arayüz_adı>_tkeep` kalıbına uyması gerekiyor (örn. arayüz adı `s0_axis` ise `s0_axis_tdata`,
`s0_axis_tvalid`, ...). **Bu, ADR-006'da yazılı değil ama RTL yazarken zorunlu bir kısıt** —
Kişi B'nin en üst modülün port isimlerini bu kalıba uydurması gerekiyor, yoksa Block Design'da IP
paketlerken arayüz manuel tanımlanmak zorunda kalır (yapılamaz değil, ama gereksiz ek iş).
**Somut aksiyon:** üst modülün port listesi ilk yazıldığında bu kalıp baştan uygulanmalı.

---

## 3. Doğrulama / Kontrol Edilebilirlik

Kaynak: [Doulos — Coverage-Driven Verification Methodology](https://www.doulos.com/knowhow/systemverilog/uvm/easier-uvm/easier-uvm-deeper-explanations/coverage-driven-verification-methodology/),
[Controllability vs Observability Coverage](https://www.researchgate.net/figure/Observability-versus-controllability-coverage_fig7_226149159),
[ben-marshall/awesome-open-hardware-verification](https://github.com/ben-marshall/awesome-open-hardware-verification).

### 3.1 Controllability / observability nedir, bize ne fark ettirir

Doğrulamada iki ayrı metrik var: **controllability** (bir tasarım durumunu test vektörüyle
tetikleyebiliyor musun) ve **observability** (o durumun etkisi gözlemlenebilir bir noktaya kadar
yayılıyor mu, yoksa içeride mi kayboluyor). Çoğu coverage metriği yalnızca controllability'yi
ölçer — bir sinyalin her değeri tetiklendi mi bakar, ama o değerin **sonuca yansıyıp
yansımadığını** görmez. Observability'yi ölçmenin pratik yolu: testler boyunca assertion sayısını
saymak (assertion, iç durumu gözlemlenebilir bir noktaya taşıyan mekanizmadır).

**Bizim projeye somut etkisi:** [[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün
`T_NUM_REQ_001` testi zaten controllability'yi doğru çözmüş — rastgele vektör yerine kasıtlı tie
üreteci kullanıyor, çünkü "rastgele test bir tie'ı asla vurmaz" (200.000 vektörde 0 tie, oturumda
ölçülmüş). Bu tam olarak controllability sorunu: nadir bir durumu (tie) test vektörüyle bilerek
tetiklemek. **Eksik olan:** observability tarafı — requantizer testinde çıktı doğrudan
karşılaştırılıyor (bu iyi, observability zaten yüksek bir test için), ama systolic array ve AXI
wrapper gibi daha derin modüllerde ara sinyalleri (örn. her PE'nin kısmi toplamı) dışarı
gözlemleyebilecek debug/monitor noktaları RTL'ye baştan eklenmeli — sonradan eklemek pipeline'ı
bozar.

### 3.2 ADR-009'un iki katmanlı yaklaşımı gerçek pratikle örtüşüyor mü

Aldec'in FPGA doğrulama akışı ve MosChip'in ASIC/SoC metodolojisi ikisi de aynı sırayı öneriyor:
**önce blok seviyesi (izole, kolay debug), sonra sistem seviyesi (entegre, PS/DMA/IP dahil)**.
Bu birebir [[ADR-009 Doğrulama Ortamı|ADR-009]]'un Katman 1 (cocotb+Icarus, saf RTL) / Katman 2
(XSim+SV, Xilinx IP'li sistem) ayrımı. **Ek olarak önerilen, ADR-009'da yazılı olmayan iki şey:**

1. **`cocotb-coverage`** — cocotb'ye constrained-random stimulus ve functional coverage ekleyen
   açık kaynak bir kütüphane ([cocotb/cocotb-coverage](https://github.com/mciepluc/cocotb-coverage)).
   Şu an ADR-003'ün test vektör üreteci elle yazılmış (kasıtlı tie + sınır + rastgele karışımı) —
   bu doğru bir başlangıç ama Katman 1 büyüdükçe (systolic array, line buffer testleri) coverage
   metriği olmadan "yeterince test ettik mi" sorusu subjektif kalır. **Öneri:** Katman 1 testbench
   iskeleti kurulurken `cocotb-coverage`'ı en azından PE ve requantizer testlerinde dene.
2. **`svlint`** ([dalance/svlint](https://github.com/dalance/svlint)) — açık kaynak SystemVerilog
   linter. ADR-003'ün "Verilog signedness tuzağı" (unsigned operand tüm ifadeyi unsigned yapar)
   tam olarak bir linter'ın yakalayabileceği sınıfta bir hata. RTL yazımı başlamadan önce
   `svlint`'i CI'a (Roadmap §9: "CI'da yalnızca Katman 1 koşabilir") eklemek, bu tuzağın koda
   girmesini synthesis'e kadar beklemeden yakalar.

### 3.3 CDC — bulunamayan araç, aslında sorun değil

awesome-open-hardware-verification listesinde **açık kaynak bir CDC (clock domain crossing)
kontrol aracı yok** — formal doğrulama araçları (SymbiYosys) kısmen kapsıyor ama özel bir CDC
linter'ı eksik. **Bu bizim için risk değil, [[ADR-008 Clock Domain Stratejisi|ADR-008]]'in tek
clock domain kararını dolaylı olarak doğruluyor**: eğer PL içinde gerçekten hiç CDC yoksa, açık
kaynak bir CDC aracının eksikliği hiç önemli değil. Xilinx'in kendi `report_cdc`'i (Roadmap §8.4,
zaten planlı) PS-PL sınırındaki AXI interconnect'in iç CDC'si için yeterli.

---

## 4. Test Aşaması Değerlendirmesi

Kaynak: [Aldec — FPGA Design Verification in a Nutshell](https://www.aldec.com/en/company/blog/194--fpga-design-verification-in-a-nutshell),
[MosChip — ASIC and SoC Verification Methodology](https://moschip.com/blog/silicon-engineering-services/asic-and-soc-verification-a-comprehensive-methodology-guide/).

### 4.1 Aşamalı test planı — Roadmap §5 üzerine eşlenmiş

Aldec'in önerdiği aşama sırası (plan → blok seviyesi TB → sistem seviyesi TB → lab bring-up) ve
test tipi ilerlemesi (basit → stres → rastgele → hata) zaten Roadmap §5'in RTL geliştirme
sırasıyla (aritmetik temel bloklar → systolic array → görüntü veri yolu → CNN katmanları → AXI
shell) ve §10'daki test kategorileriyle uyumlu. Somut eşleme:

| Aldec aşaması | Roadmap §5 karşılığı | Roadmap §10 test kategorisi |
|---|---|---|
| Blok seviyesi (izole) | Aşama 1: multiplier, accumulator, requantizer | §10.1 Unit testleri (sıfır, min/max signed, overflow, saturation) |
| Blok seviyesi (izole) | Aşama 2: tek PE → 2×2 → parametrik N×N | §10.1 + "array boyutuna bölünmeyen matris" |
| Sistem seviyesi (entegre, henüz PS yok) | Aşama 3-4: line buffer, window generator, CNN katmanları | §10.3 Numerik testler (katman bazlı bit-exact) |
| Sistem seviyesi (PS dahil) | Aşama 5: AXI shell | §10.2 AXI4-Stream testleri (backpressure, TLAST, reset) |
| Lab bring-up | Board geldikten sonra (Aşama 2, Ekim) | §10.5 Sistem testleri (DMA loopback, cold boot) |

**Bu tablo zaten büyük ölçüde doğru kurulmuş** — araştırmanın bulduğu tek gerçek boşluk: Aldec'in
"basit → stres → rastgele → hata" test tipi ilerlemesi, §10'da kategori olarak var ama **hangi
sırayla yazılacağı belirtilmemiş**. Öneri: her modül için önce basit yönlü (directed) test, sonra
sınır/stres, en son rastgele — rastgeleyi en başa koymak (özellikle ADR-003'ün tie örneğinde
kanıtlandığı gibi) nadir durumları asla yakalamaz.

### 4.2 MosChip'in 10 adımlı akışıyla karşılaştırma — eksik olan tek adım

MosChip'in akışında bizde açıkça karşılığı olmayan tek adım: **"assertion-based checking kritik
yollarda"** (adım 5). Roadmap §10.6'da bir SVA örneği var (`axis_stable_during_stall`) ama bu tek
bir örnek, sistematik bir assertion planı değil. **Somut öneri:** RTL yazımına başlarken her modül
için "bu modülün asla ihlal etmemesi gereken 2-3 protokol/invariant kuralı ne" sorusunu sor ve
assertion olarak modülün içine göm (SVA veya cocotb içinde `assert` — Katman 1'de cocotb
kullanıldığı için Python tarafında da yapılabilir). Requantizer için örnek: "n=0 asla olmaz",
"M0 her zaman `[2^16, 2^17)` aralığında" gibi ADR-003'ün kendi kısıtları doğrudan assertion'a
dönüşebilir.

### 4.3 Verification plan'in "bağlayıcı sözleşme" rolü — zaten var, ismi farklı

MosChip'in vurguladığı "verification plan mimari, RTL ve doğrulama arasında bağlayıcı sözleşmedir"
ilkesi bizim projede zaten **ADR'ler + Roadmap §6 (Tasarım sözleşmeleri) + §6.6 (Verification Plan
ve traceability tablosu)** olarak var — isim farklı ama fonksiyon aynı. Tek fark: MosChip'in
önerdiği "her gereksinimin en az bir testi, her testin en az bir gereksinimi olması" kuralı
Roadmap §6.6'da yazılı ama şu an tablo örnek/iskelet durumda (6 satır), gerçek testler yazıldıkça
güncellenmesi gerekiyor — bu bir eksiklik değil, henüz sırası gelmemiş bir iş.

---

## Somut Öneriler — Yarın İçin

1. **`T_NUM_REQ_001`'i yaz** (zaten Threads.md'de sıradaki iş olarak işaretli) — bu araştırma
   onun önceliğini değiştirmiyor, doğruluyor: hem controllability (§3.1) hem "array'den önce
   bağımsız test edilebilir blok" deseni (§1.2, §1.3) hem de MosChip'in "erken assertion" önerisi
   (§4.2) requantizer'ın ilk yazılacak şey olması gerektiğini işaret ediyor.
2. **En üst modülün (AXI4-Stream wrapper) port isimlerini `<iface>_tdata/_tvalid/_tready/...`
   kalıbına baştan uydur** (§2.3) — sonradan değiştirmek IP paketleme aşamasında ekstra iş demek.
3. **`svlint`'i bugün kur ve ilk commit'ten itibaren CI'a ekle** (§3.2) — ADR-003'ün signedness
   tuzağı gibi hataları RTL yazılırken yakalasın, synthesis'e kadar beklemesin.
4. **Requantizer ve PE testbench'lerinde `cocotb-coverage`'ı dene** (§3.2) — en azından bir
   functional coverage grubu (örn. requant'ın tie/sınır/normal durumlarını kapsayan) kurup şu an
   elle yazılan vektör listesinin (ADR-003) coverage açısından da yeterli olduğunu doğrula.
5. **Modül sınırlarında register'lama kararını şimdi ver, sonradan ekleme** (§2.2) — özellikle
   64-bit requant hesap yolunun (ADR-003, 2026-09-25 update) nerede pipeline edileceği ilk yazımda
   netleşmeli, timing kapanmayınca RTL'e geri dönmek UG949'un tam da kaçınmamızı söylediği şey.
6. **8 banka/8 requantizer gibi tekrarlayan yapılarda tek ortak reset/enable kullan** (§2.2) —
   control set israfını baştan önle.
7. **Her modül için 2-3 invariant belirleyip assertion olarak göm** (§4.2), test yazmadan önce.
