---
title: ADR-014 Requantizer Port ve Zamanlama Sözleşmesi
created: 2026-09-25
modified: 2026-09-25
type: decision
status: önerildi
tags: [dnn-accelerator, adr, kontrat, rtl, requantizer, timing]
---

# ADR-014: Requantizer Port ve Zamanlama Sözleşmesi

## Durum
**Önerildi — Kişi B onayı bekliyor (2026-09-25).**

[[ADR-003 INT8 Fixed-Point Formatı|ADR-003]] requantizer'ın *matematiğini* kilitledi ama
*arayüzünü* tanımlamadı: valid/ready davranışı, latency, parametrelerin hangi cycle'da
örneklendiği ve stall sırasında ne olduğu açıktı. Bu ADR o boşluğu kapatıyor.

| Madde | Durum |
|---|---|
| Port listesi (`out_y_raw` dahil) | **Türetilmiş** — ADR-003 `T_NUM_REQ_001` pre-clamp karşılaştırması zorunlu kılıyor |
| Sabit ve bilinir latency; `LAT` parametre, sihirli sabit değil | **Türetilmiş** |
| `out_ready` → `in_ready` kombinasyonel yol yasağı | **Türetilmiş** — Roadmap §7.1 |
| `k_last` kapısı: requantizer yalnız tamamlanmış `K` indirgemesini görür | **Türetilmiş** — ADR-002 `K_MAX=8` chunk notu |
| Assertion listesi | **Türetilmiş** |
| Config'in veriyle birlikte pipeline'da akması | Onay bekliyor |
| Stall'da tek clock-enable ile tüm pipe'ın donması | Onay bekliyor |
| K-streaming (chunk'lama değil) | Onay bekliyor |
| `LAT = 5` | **Ölçüldü** (2026-10-05) — sentez/timing; `LAT = 3` kapanmadı, aşağıya bkz. |

## Karar

### Port listesi

```verilog
module requant_unit #(
  parameter int ACC_W  = 32,
  parameter int M0_W   = 18,   // signed, MSB daima 0
  parameter int PROD_W = 64,   // ADR-003: product + rounding offset + shift
  parameter int LAT    = 5     // sabit ve bilinir; TB bu parametreyi okur
)(
  input  logic                    clk,
  input  logic                    rst_n,        // async assert, sync deassert (ADR-008)

  // --- config: örnekle birlikte akar, pipeline'da "canlı" değildir ---
  input  logic signed [ACC_W-1:0] cfg_bias_q,
  input  logic signed [M0_W-1:0]  cfg_m0,
  input  logic        [5:0]       cfg_shift_n,  // unsigned (ADR-003)
  input  logic                    cfg_relu,     // 1 → lo=0, 0 → lo=-128
  input  logic                    cfg_bypass,   // son katman: acc'yi ham geçir

  // --- giriş ---
  input  logic                    in_valid,
  output logic                    in_ready,
  input  logic signed [ACC_W-1:0] in_acc,
  input  logic                    in_k_last,    // K indirgemesi tamamlandı (bkz. aşağıda)
  input  logic                    in_last,      // tile/frame sonu, veriyle taşınır

  // --- çıkış ---
  output logic                    out_valid,
  input  logic                    out_ready,
  output logic signed [7:0]       out_y,
  output logic signed [PROD_W-1:0] out_y_raw,   // pre-clamp; T_NUM_REQ_001 için zorunlu
  output logic                    out_last,
  output logic                    out_sat,      // bu örnekte clamp tetiklendi
  output logic                    out_ovf       // bias toplamında 32-bit wrap taşması
);
```

`out_y_raw` sentezde bağlanmazsa optimize edilir, maliyeti sıfır. Hiyerarşik referans
(`dut.u_req.y_raw`) yerine gerçek port tercih edildi: modül yeniden düzenlenince sessizce
kırılmaz.

### Pipeline

| Stage | İş |
|---|---|
| S0 | `a = wrap32(in_acc + cfg_bias_q)`, `ovf` tespiti; config bundle burada örneklenir |
| S1 | `p = a · cfg_m0` (DSP48E1 ×2, cascade; 32×18 tek DSP'ye sığmaz) |
| S2 | `p + half_ulp(n)` (64-bit add; `half_ulp` 6→64 one-hot decoder) |
| S3 | `raw = cfg_bypass ? a : (s >>> n)` (64-bit variable arithmetic shift) |
| S4 | `clamp(lo,127)` → `out_y`, `out_sat` (result register) |

**`LAT = 5`, ölçümle belirlendi (2026-10-05).** Bu ADR `LAT = 3`'ü "ölçüm bekliyor"
olarak işaretlemişti ve 100 MHz'de S2 sıkışırsa shift/clamp ayrılıp `LAT = 4` olacağını
öngörmüştü. Ölçüm yapıldı, öngörü doğru çıktı ama bir adım daha gerekti.

Üç stage'li hal OOC sentezde (xc7z020clg400-1, 100 MHz) **WNS −2.509 ns** verdi: kritik yol
`s1_shift_n` → `s2_sat`, **34 logic level, 24 CARRY4, 12.502 ns**; bunun 6.423 ns'si salt
logic, yani stage yapısal olarak uzundu, yerleşim sorunu değildi.

Stage başına ölçülen gecikmeler (beş stage'li halde):

| Stage | Datapath | Logic levels | Slack |
|---|---|---|---|
| S2 (decode + add) | 4.521 ns | 18 (16 CARRY4) | +5.504 ns |
| S3 (variable shift) | 4.212 ns | 5 LUT | +5.781 ns |
| S4 (clamp) | 2.582 ns | 2 LUT | +7.165 ns |
| S1 (DSP cascade) | 4.261 ns | 0 | **+4.255 ns ← limit** |

Beş stage'de limit artık aritmetik değil, **DSP48 cascade'i**; aritmetik stage'lerin hepsinde
5,5 ns'den fazla pay var. Yani beşinci stage frekansa hiçbir şey ödetmiyor. `LAT = 4`
kurulabilirdi (add | shift+clamp ≈ 6,79 ns → tahmini ~+2,4 ns pay) ama bu, ölçülen 4,255 ns
payı ~2,4 ns'ye düşürmek karşılığında tile kuyruğunda bir cycle kazandırırdı — Conv1'in
112 invocation'ında ~%0,45. Entegrasyon top'u ve full route/STA henüz yapılmadığı için
pay korundu.

Maliyet: `requant_unit` 2 DSP48 / 658 LUT / 508 FF, **WNS +4.255 ns**. Sekiz lane'lik
`requant_array` 16 DSP48 / 4320 LUT / 2539 FF, **WNS +3.380 ns** — payload'ı iki ek stage
boyunca taşımak lane başına ~176 FF ekledi. Aritmetik ifadeler değişmedi, yalnız register
eklendi; bu yüzden 60K vektörlük `T_NUM_REQ_001` bit-exactness kanıtı geçerliliğini koruyor
ve yeniden geçti. Tek ifade değişikliği `half_ulp`: `1 << (n-1)` yerine indeksli bit atama —
aynı değer, ama sentez data shifter değil decoder çıkarıyor.

**Sözleşme sayının kendisi değil, sabit ve bilinir olmasıdır** — testbench `LAT`
parametresini okur. `tb_requant_unit_timing` LAT=4 ile koşulduğunda "no-stall latency got 5
expected 4" diye başarısız oluyor, yani değeri gerçekten çiviliyor.

### Zamanlama kuralları

1. **Throughput:** `out_ready = 1` iken 1 örnek/cycle, kabarcık yok.
2. **Backpressure:** çıkışta derinlik-2 skid buffer; `in_ready = !skid_full`, register'lı.
   `out_ready`'den `in_ready`'ye kombinasyonel yol **yoktur** (Roadmap §7.1).
3. **Stall:** tek clock-enable tüm stage register'larını birlikte dondurur. Veri düşmez,
   çoğalmaz. İki kişilik ekipte per-stage elastic handshake'ten belirgin biçimde daha kolay
   doğrulanır.
4. **Parametre örnekleme:** `cfg_*`, örnek S0'a girerken register dosyasından kombinasyonel
   okunur ve veriyle birlikte aşağı taşınır. "Parametre pipeline ortasında değişti" tehlikesi
   yapısal olarak yoktur. Banka seçimi `bank = c_out mod 8`
   ([[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] ile aynı indeksleme).
5. **Reset:** 1 cycle içinde `out_valid = 0`, `in_ready = 1`, pipe boş.
6. **`in_last` → `out_last`:** tam `LAT` cycle sonra çıkar; AXIS wrapper `TLAST`'ı bundan üretir.

### `k_last` kapısı — sessiz hata sınıfını kapatıyor

[[ADR-002 CNN Topolojisi ve Dataset|ADR-002]] mevcut tile-engine'in `K_MAX = 8` sınırıyla
`K = 400`'ü 50 chunk'a böldüğünü ve partial sonuçların toplanması gerektiğini not ediyor.

> **Requantizer yalnızca `K` indirgemesi tamamlanmış accumulator'ı görür.** Kısmi-K toplamı
> yukarı akışta biter; requantizer chunk başına tetiklenmez.

Aksi hâlde FC1'de `50 chunk × 15 tile = 750` kez requantize edilir ve sonuç **sessizce** çöp
olur — her chunk kendi içinde geçerli bir INT8 üretir, hiçbir bayrak yanmaz. Bu yüzden
`in_valid`, array'in `in_k_last` niteleyicisiyle kapılanır.

[[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün wrap taşma tespiti de **dış partial-sum
toplayıcısını kapsamalıdır**; kısmi toplamların birikimi de 32-bit'te yaşıyor.

**Önerilen çıkış: K-streaming.** ADR-002'nin kendi önerdiği "tek output tile boyunca `K`
akışı" seçilirse dış partial-sum buffer'ı tamamen ortadan kalkar, `k_last` tek sayaca iner ve
taşma bayrağının davranışı indirgeme sırasından bağımsız kalır.

## Assertion listesi

```systemverilog
in_valid && !in_ready   |=> in_valid && $stable(in_acc)
out_valid && !out_ready |=> out_valid && $stable(out_y) && $stable(out_last)
// korunum: kabul edilen == üretilen + pipe'ta bekleyen
// stall yokken: kabul ile üretim arası tam olarak LAT cycle
// in_k_last=0 olan hiçbir örnek çıkış üretmez
```

## Alternatifler
- **Config'i statik tutmak (pipeline'da taşımamak):** bedava, ama "busy iken değişmez"
  kuralına bağımlı hale gelir; [[ADR-015 Register Map ve Parametre Yükleme|ADR-015]] bunu
  zaten veriyor. Taşıma maliyeti, `LAT = 5` sonrası ölçümle **lane başına ~176 FF**
  (sekiz lane için 1131 → 2539 FF); LUT neredeyse değişmedi (4294 → 4320).
- **Per-stage elastic handshake:** daha yüksek throughput, belirgin biçimde daha fazla
  doğrulama yüzeyi. Aşama 1'in darboğazı requantizer değil.
- **`out_y_raw` yerine hiyerarşik referans:** Icarus destekliyor, ama refactor'da sessizce
  kırılır. Elendi.

## Sonuçlar
- `T_NUM_REQ_001` bu porta bağımlı; ADR-014 olmadan test yazılamaz.
- Kişi B'nin Hafta 5-6 iş yüküne skid buffer ve `k_last` sayacı eklenir.
- K-streaming seçilirse ADR-002'nin tile tablosundaki "micro-run" sütunu yeniden hesaplanır.

## Ek madde — 2026-09-26: implementasyon sırasında kapatılan üç boşluk

Bu ADR'nin port listesi uygulanırken üç madde tanımsız çıktı. Üçü de implementasyonu bloke
ettiği için karara bağlandı; ADR hâlâ `önerildi` olduğundan bunlar da Kişi B onayına dahildir.

### 1. `cfg_bypass` ne üretir

ADR yalnız "son katman: acc'yi ham geçir" diyordu; hangi porttan, hangi genişlikte ve
`out_y`'nin ne olacağı açıktı.

> **Bypass'ta `out_y_raw`, bias eklenmiş INT32 accumulator `a`'yı `PROD_W`'ye sign-extend
> edilmiş olarak taşır.** Çarpım/yuvarlama/kaydırma uygulanmaz. `out_y` yine
> `clamp(lo,127,a)` taşır ve `out_sat` o clamp'i bildirir — port hiçbir zaman X kalmaz ama
> downstream `out_y_raw[31:0]`'ı tüketir. `out_ovf` bias toplamı taşmasını normal yolda
> olduğu gibi bildirir. **Gecikme bypass'ta da tam `LAT`'tır**: bypass bir mux, kısayol
> değil — zamanlama iki yolda birebir aynı kalır.

[[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]] §4'ün "son katman 10 × INT32
logit döndürür" kararının donanım tarafı budur.

### 2. `in_k_last = 0` olan örneğin el sıkışması

ADR "`in_k_last=0` olan hiçbir örnek çıkış üretmez" assertion'ını veriyordu ama örneğin
kabul mü edildiği, yoksa reddedildiği mi belirsizdi. İkisi farklı sonuç doğuruyor:

> **Örnek el sıkışmasını normal şekilde tamamlar** (`in_ready` aynı davranır, örnek tüketilir)
> ve **düşürülür**, çıkış beat'i üretmez. Üzerinde **asla stall edilmez.**

Gerekçe: `in_k_last = 0` üzerinde stall etmek yukarı akıştaki indirgeyiciyi kilitler —
indirgeyici `k_last`'ı ancak akışı ilerleterek üretebilir, requantizer akışı durdurursa
ikisi birbirini bekler. Bu, kapatılmak istenen sessiz hata sınıfını bir deadlock'la
değiştirmek olurdu.

### 3. Dış partial-sum toplayıcısı maddesi düştü

Bu ADR "[[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün wrap taşma tespiti dış partial-sum
toplayıcısını da kapsamalıdır" diyordu. [[ADR-018 K-Streaming ve Ara Aktivasyon Düzeni|ADR-018]]
K-streaming'i kilitleyince **dış toplayıcı yok**: accumulator tüm `K` boyunca PE'de kalıyor.
Madde düşüyor, taşma tespiti tek yerde (PE accumulator'ı + requantizer S0 bias toplamı) yaşıyor.

`in_k_last` da böylece tek sayaç karşılaştırmasına iniyor ve ADR-018'in drain şemasından
geliyor: drain yalnız tamamlanmış indirgemeden sonra olduğu için **her drain beat'i
`k_last`'tır.**

### 4. `out_sat` bypass'ta 0'dır

İlk taslakta bypass'ta da clamp'in `out_sat`'a yansıması söylenmişti. Bir blok aşağıya
bakınca yanlış olduğu görüldü: [[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]
§4'ün STATUS beat'inde `sat_seen` biti var ve bypass'ı kullanan **tek** katman son katman.
Orada `raw = a` tam bir INT32 logit, yani `|a| > 127` neredeyse her zaman doğru — `out_sat`
her son-katman örneğinde yanar ve `sat_seen` her frame'de 1'e kilitlenip **hiçbir bilgi
taşımaz.**

> **Bypass örneğinde `out_sat = 0`.** Saturation quantization'ın bir özelliğidir; bypass'ta
> quantization olmadığı için bayrak tanımı gereği yanlıştır, doğru değil.

`out_y` yine `clamp(lo,127,a)` taşır (debug için tanımlı ve X olmayan kalır) ve `out_ovf`
bypass'ta da bias toplamı taşmasını bildirir — o bayrak anlamlı kalıyor.

### 5. `in_last && !in_k_last` yasak giriştir

Madde 2 düşürülen örneğin el sıkışmasını tanımladı ama o örneğin `in_last`'ına ne olduğunu
söylemedi. Düşürülürse **frame sınırı sessizce kaybolur**: AXIS wrapper TLAST görmez, DMA
transferi hiç bitmez ve arıza sebepten çok uzakta bir hang olarak yüzeye çıkar.

Çözüm bayrağı ileri taşımak **değil**, girişi yasaklamak:

> `in_valid && in_last` → `in_k_last` zorunlu. Aksi kombinasyon concurrent assertion ile
> yakalanır ve mesajı bunu bir birim hatası değil **yukarı akış yasak girişi** olarak
> adlandırır.

Gerekçe: `in_last` tile/frame sınırı demek, sınır da tanımı gereği tamamlanmış bir
indirgemedir. [[ADR-018 K-Streaming ve Ara Aktivasyon Düzeni|ADR-018]]'in drain yapısı bunu
zaten garanti ediyor. Bayrağı veri yolunda ileri taşımak yasak girişi sessizce
yaşanabilir kılardı — kapatılmak istenen sessiz hata sınıfı tam olarak böyle içeri girmişti.

### Drain şekli — neden kolon kolon, 8 lane

ADR-018 tile'ı 8 çıkış lane'i (satır = çıktı kanalı) hâlinde, cycle başına bir kolon olarak
drain ediyor. Sebebi doğrudan bu ADR'nin config modeli: [[ADR-015 Register Map ve Parametre
Yükleme|ADR-015]] parametreleri **çıktı kanalı** başına tanımlıyor (`bank = c_out mod 8`),
dolayısıyla hep aynı kanalı taşıyan bir lane hep aynı `(M0, n, bias_q)` demetini taşır.
Satır satır drain edilseydi config her cycle değişirdi — bu ADR'nin "config veriyle birlikte
akar" kuralı çalışmaya devam ederdi ama 8 birimin hepsine her cycle yeni demet yazmak
gerekirdi.
