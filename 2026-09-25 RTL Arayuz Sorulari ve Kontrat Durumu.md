---
title: RTL Arayüz Soruları ve Kontrat Durumu — 2026-09-25
created: 2026-09-25
type: note
status: active
tags: [dnn-accelerator, kontrat, adr, rtl, ml]
---

# RTL Arayüz Soruları ve Kontrat Durumu — 2026-09-25

Bu belge iki şeyi bir arada tutuyor: **(1)** Aşama 1 kontratlarının 25 Eylül 2026 itibarıyla
son hâli, **(2)** RTL tarafından gelen altı açık arayüz sorusunun cevabı.

Her cevap üç durumdan biriyle işaretli:

| İşaret | Anlamı |
|---|---|
| 🔒 **Kilitli** | ADR'ye yazıldı, bağlayıcı. Değişmesi ADR revizyonu gerektirir |
| 📋 **Önerildi** | ADR yazıldı, `status: önerildi`. Kişi B onayı sonrası kilitlenir |
| ❓ **Açık** | Karar için eksik girdi var; nereden geleceği aşağıda yazılı |

---

## Kontratların son hâli

| ADR | Konu | Durum |
|---|---|---|
| ADR-001 | PYNQ-Z2 `xc7z020clg400-1`, Vivado 2024.1 + PYNQ v3.1 | 🔒 |
| ADR-002 | LeNet-5, 32×32 RGB, 5×5 valid conv, 2×2/2 max-pool, `3→6→16`, FC `400→120→84→10` | 🔒 |
| ADR-003 | Simetrik INT8, per-output-channel ağırlık scale, **INT32 wrap accumulator**, **signed 64-bit requant yolu**, round-half-up | 🔒 (25 Eyl revizyonu) |
| ADR-004 | 8×8 systolic array (64 PE), output-stationary | 🔒 |
| ADR-005 | Doğrudan streaming convolution, line buffer + window generator | 🔒 |
| ADR-006 | AXI4-Stream `TDATA=64b`, `TLAST`=frame sonu, `TUSER` yok, `TKEEP` all-1 | 🔒 (ADR-016'ya bağımlı, aşağıda) |
| ADR-007 | Simple/Direct Register Mode DMA | 🔒 |
| ADR-008 | Tek clock domain, 100 MHz | 🔒 |
| ADR-009 | İki katmanlı doğrulama: cocotb+Icarus (birim) / XSim+SV (sistem), dosya köprüsü | 🔒 |
| ADR-011 | PyTorch native ağırlık düzeni, 8 banka (`c_out mod 8`), `addr = t*K + k` | 🔒 (+ FC1 istisnası, aşağıda) |
| **ADR-014** | **Requantizer port ve zamanlama sözleşmesi** | 📋 **yeni** |
| **ADR-015** | **Register map ve parametre yükleme protokolü** | 📋 **yeni** |
| **ADR-016** | **Aktivasyon tensör düzeni ve byte yerleşimi** | 📋 **yeni** |
| ADR-012 | Çalışma zamanında ağırlık yükleme | ❓ Aşama 2 başlarken |
| ADR-013 | Skip connection / residual desteği | ❓ En geç Aşama 2 sonu |

**Referans geometry (ADR-002, kilitli):**

| Layer | Output | `K` | Output-channel tile |
|---|---|---:|---:|
| Input | `32×32×3` | — | — |
| Conv1 | `28×28×6` | 75 | 1 |
| Pool1 | `14×14×6` | — | — |
| Conv2 | `10×10×16` | 150 | 2 |
| Pool2 | `5×5×16` | — | — |
| FC1 | 120 | 400 | 15 |
| FC2 | 84 | 120 | 11 |
| FC3 | 10 | 84 | 2 |

---

## 1. `n` aralığı ve geçersiz `n` davranışı — 🔒 Kilitli

**Karar:** `n` unsigned 6-bit, **`0..63`'ün tamamı aritmetik olarak tanımlı**. Requant hesap
yolu signed **64-bit**: `|acc·M0| < 2^48`, `n=63 → half_ulp = 2^62`, toplam `< 2^63`.
`half_ulp = (n == 0 ? 0 : 2^(n-1))`.

Bu, ilk taslaktaki "yasal aralık `[1,49]` + donanım hata yolu" önerisinden farklı ve daha iyi:
50-bit'te sınır gerçekten `n ≤ 49` idi, 64-bit'te **hiçbir `n` değeri tanımsız davranış
üretmiyor**. Maliyet ~%0,2 LUT.

**Geçersiz/anlamsız `n` nasıl bildirilir:**

| Katman | Davranış |
|---|---|
| Kişi A export script'i | `assert 1 <= n <= 49` — **birincil kapı**, hata build zamanında patlar |
| `PARAM_COMMIT` (ADR-015) | `ERR_CFG_SHIFT` — **opsiyonel kanarya**, korrektlik için gerekli değil |
| RTL aritmetiği | Sessiz clamp **yok**. Her `n` tanımlı ve Python golden ile bit-exact |

`n = 0` fiziksel olarak ulaşılamaz (`M0 ≥ 2^16` → `M ≥ 65536`, her çıktı doyar); `n ≥ 33` da
öyle (`M < 1,1e-5`). Pratik bant `n ≈ 20–27`.

> **Yan etki — Kişi B'nin bilmesi gereken:** `n = 0` yasallaşınca "`SHIFT` reset değeri 0 →
> yapılandırılmamış cihaz başlayamaz" garantisi kayboldu. Reset sonrası
> `M0 = 0, n = 0, bias = 0` ile cihaz sessizce `y = 0` üretirdi. Guard
> **`M0 ∈ [2^16, 2^17)`** kontrolüne taşındı; `ERR_CFG_M0` artık **zorunlu** (ADR-015).

**Test (`T_NUM_REQ_001`) — ölçülmüş bulgu:** tie vektörlerinin final INT8 sonuçları saturation
ile maskeleniyor. 10 farklı `(n, M0)` çiftinin **onunda da** yalnız INT8 çıktıyı karşılaştıran
test, half-up ile nearest-even'ı ayırt edemedi (ardışık tie'lar arasında
`Δy_raw = M0 ≥ 2^16`). Karşılaştırma **pre-clamp `y_raw`** üzerinde yapılmak zorunda. Ayrıca
`n ≥ 33`'te INT32 penceresine hiç tie düşmüyor → boş liste assertion'ı ve `n` süpürmesi
gerekli. Tam tablo ADR-003'te.

---

## 2. INT32 taşma politikası — 🔒 Kilitli

**Karar:** **wrap (modulo `2^32`, two's complement)**. Accumulator'da saturation yok; INT8
saturation yalnız requant çıkışında.

```python
wrap32(v) = ((v + 2**31) % 2**32) - 2**31
```

**Gerekçe:** saturating toplama birleşmeli (associative) değildir — seçilseydi integer golden
model array'in MAC sırasını birebir taklit etmek zorunda kalırdı. `wrap32` altında toplama
birleşmeli olduğu için golden model tam hassasiyette toplayıp **sonda bir kez** sarabilir.

**Taşma Aşama 1'de yapısal olarak imkânsız:** `|x·w| ≤ 2^14`, tavan FC1'de
`K = 400 → |acc| ≤ 6.553.600`, `2^31`'e **328× marj**. Taşma bir numerik risk değil,
config/export hatası göstergesidir.

**Güvenli yeter koşul — Kişi A'nın export'unda katman başına doğrulanır:**

```python
assert abs(bias_q) + K * 16384 <= 2**31 - 1
```

**Donanım tespiti opsiyonel:** per-add işaret kuralı → sticky `ERR_ACC_OVF`, frame kesilmez,
PS `done` sonrası ERROR'ı okur. Muhafazakârdır (sarıp geri dönen ara toplamda da yanar).
Asıl güvence yukarıdaki export proof'u; bayrak Aşama 3'e taşınma güvenliği için tutuluyor —
ADR-003 bu proof'un Aşama 3 modeline kendiliğinden aktarılmadığını açıkça yazıyor.

> **Kişi A tarafında değişiklik:** `requant_ref()` artık taşmada **hata fırlatmamalı**, açık
> `wrap32` uygulamalı. Önerilen imza `(y, sat, ovf)` — bayraklar da bit-exact sözleşmenin
> parçası.

---

## 3. INT8 dönüşümünün yeri; pool ve flatten boyunca scale — 🔒 Kilitli

`cnn_pipeline/model.py` doğruladı: **`Conv2d → ReLU → MaxPool2d`**, model `LeNet5ReLUMaxPool`.
Max-pool olduğu kesinleştiği için aşağıdaki sözleşme geçerli. (Average pooling seçilseydi
scale-koruma maddesi geçersiz olur, ayrı bir numerik spec gerekirdi.)

**Karar:** katman başına **tam bir kez** requantize; array çıkışında, pooling'den **önce**.
Max-pool ve flatten INT8 alanında çalışır, `s_y` ve `z = 0` **değişmeden** taşınır.

```
INT8 (s_x) → array → INT32 acc → +bias_q → ·M0 → +half_ulp → >>>n → clamp(lo,127) → INT8 (s_y)
                                                                                        |
                                       max-pool [INT8, s_y aynı] -- flatten [s_y aynı] --+
```

- **Neden pool requant'tan sonra:** `z = 0, s > 0` ve max monoton → `max(q_i)·s = max(q_i·s)`.
  Pooling quantize alanda birebir eşdeğer, ek yuvarlama yok. INT32'de pool 4× buffer ve 32-bit
  karşılaştırıcı demek, karşılığında sıfır numerik kazanç.
- **ReLU:** ayrı aşama değil, clamp'in alt sınırı (`lo = 0`). `pool(relu(x)) = relu(pool(x))`
  olduğu için pool sırası bunu bozmuyor.
- **Son katman (FC3):** ReLU yok → `lo = -128`. **Requant bypass edilir**, 10 × INT32 logit
  PS'e gider (bkz. Soru 6). 📋
- **`s_y` kalibrasyonu:** **pre-pool** tensöründen (requantizer çıkışı) — observer, clamp'in
  fiilen etki ettiği tensörün üstünde durmalı. 📋

**Gözlem noktaları** (Roadmap §4.3 ile birebir), katman başına üç dosya:

| Golden model çıktısı | RTL karşılığı | Genişlik |
|---|---|---|
| accumulator | array çıkışı, bias sonrası / `·M0` öncesi | INT32 |
| requantization | clamp çıkışı (ReLU dahil) | INT8 |
| ReLU/pooling | pool çıkışı | INT8, aynı `s_y` |

> **Kişi A tarafında değişiklik — FC1 ağırlık permütasyonu.** Aktivasyonlar HWC saklanıyor
> (ADR-016), yani Pool2 çıktısı bellekte `[h][w][c]`; PyTorch `flatten` ise NCHW üzerinden
> `[c][h][w]` üretiyor. Tek satır, host tarafı:
> ```python
> w_fc1 = w_fc1.reshape(120, 16, 5, 5).permute(0, 2, 3, 1).reshape(120, 400)
> ```
> ADR-011'in "dönüşümsüz export" maddesi conv için doğru, FC1 için değil. Yazılmazsa ağ
> çalışır ama doğruluk şans seviyesine düşer ve donanımda hiçbir bayrak yanmaz.

---

## 4. Requantizer port ve zamanlama sözleşmesi — 📋 ADR-014

**Türetilmiş (tartışmasız) maddeler:**

- Port listesi; **`out_y_raw` (signed 64-bit, pre-clamp) zorunlu** — `T_NUM_REQ_001` bunu
  görmek zorunda (bkz. Soru 1). Hiyerarşik referans yerine gerçek port: refactor'da sessizce
  kırılmaz, bağlanmazsa sentezde optimize edilir.
- **Sabit ve bilinir latency.** Sözleşme sayının kendisi değil, sabitliği: `LAT` parametre,
  testbench onu okur. Hedef `LAT = 3` (S0 bias+wrap, S1 DSP çarpım,
  S2 `+half_ulp`/shift/clamp); 100 MHz'de S2 sıkışırsa `LAT = 4`. ❓ sentez sonucu
- **`out_ready` → `in_ready` kombinasyonel yolu yasak** (Roadmap §7.1). Çıkışta derinlik-2
  skid buffer, `in_ready = !skid_full`, register'lı.
- **`k_last` kapısı:** requantizer yalnızca `K` indirgemesi tamamlanmış accumulator'ı görür.
  ADR-002'nin `K_MAX=8` chunk'lama notu bunu zorunlu kılıyor — aksi hâlde FC1'de
  `50 chunk × 15 tile = 750` kez requantize edilir ve sonuç **sessizce** çöp olur (her chunk
  kendi içinde geçerli bir INT8 üretir, hiçbir bayrak yanmaz). Taşma tespiti de dış
  partial-sum toplayıcısını kapsamalı.
- Assertion listesi: stabilite (`valid && !ready |=> $stable`), korunum (kabul = üretilen +
  pipe'ta bekleyen), `LAT` sabitliği, `k_last=0` olan örneğin çıkış üretmemesi.

**Onay bekleyen:** config'in veriyle pipeline'da akması (alternatif: statik tutma) · stall'da
tek clock-enable ile tüm pipe'ın donması (alternatif: per-stage elastic) · K-streaming
(ADR-002'nin kendi önerisi) vs K-chunking.

---

## 5. Parametre yükleme: adresler, bit alanları, "tamamlandı" koşulu — 📋 ADR-015

**"Yükleme tamamlandı" koşulu = `PARAM_COMMIT.COMMIT`'in başarılı dönmesi.**

1. 8 banka × 3 word = **24 yazma** → **shadow** register dosyası, her yazma `written_mask`'te
   bit set eder. Aktif parametrelere doğrudan yazılamaz.
2. `COMMIT` → donanım doğrular: mask tam, her `M0 ∈ [2^16, 2^17)` (**zorunlu**),
   her `n ∈ [1,49]` (opsiyonel kanarya).
3. Geçerse shadow → active **atomik** kopya, `COMMITTED = 1`. Geçmezse ilgili `ERROR` biti,
   **kopya yok, aktif parametreler dokunulmaz**.
4. `START`, `COMMITTED == 0` iken reddedilir → `ERR_PARAM_INCOMPLETE`.
5. `BUSY` iken shadow'a yazmak serbest (tile `t+1` hazırlanabilir), commit reddedilir
   (`ERR_CFG_WR_BUSY`). Tile sınırında ertelenmiş commit Aşama 2 yükseltmesi.

**Neden shadow+commit, "start zaten son yazmadır" değil:** 24 word AXI4-Lite üzerinden atomik
yazılamaz; yarım yüklenmiş set sessiz yanlış sonuç üretir. Commit ayrıca aralık kontrollerinin
doğal yeri.

Tam register map (offset, bit alanı, reset değeri, R/W tipi, W1C davranışı) ADR-015'te.

**Ölçüm gerektiren nokta:** parametreler output-channel tile'ı başına değişir (output-position
tile'ı başına değil) → inference başına **31 yükleme × 25 yazma = 775 AXI4-Lite yazma**.
Hesap toplamı 18.738 cycle ≈ 187 µs @100 MHz.

| Yazma gecikmesi | Toplam | Hesaba oranı |
|---|---:|---:|
| 0,1 µs (bare-metal) | 78 µs | %41 |
| 1 µs (PYNQ Python MMIO) | 775 µs | **4×** |

Yük tamamen FC'de (28 yükleme / 7.488 cycle); conv'da ihmal edilebilir (3 yükleme /
11.250 cycle). Bu, ADR-007'de belgelenen Huynh AXI-Lite darboğazının küçük kardeşi. Bu yüzden
`TILE_CFG.PARAM_SRC` mux'ı (`0` = AXI-Lite register dosyası, `1` = BRAM'den tile indeksiyle
otomatik yükleme, katman başına bir `layerN_requant.coe`) **şimdi konuyor** — sonradan eklemek
register map'i kırar. Aşama 1'de `PARAM_SRC = 0` kullanılacak. ❓ gerçek yazma gecikmesi bir
kez ölçülmeli

---

## 6. Akış sırası, byte yerleşimi, çıkış paketi — 📋 ADR-016

**Sıra: HWC** (kanal en hızlı değişen eksen).

| | HWC | CHW |
|---|---:|---:|
| Conv1 tamponu (`kH-1 = 4` satır) | `4 × 32 × 3 = 384 B` | `28×28×8×4 = 25.088 B` kısmi toplam |

CHW imkânsız değil (25 KB Zynq-7020'ye sığar) ama ~65× pahalı ve üç geçiş gerektirir. Ayrıca
array bir çıkış pikselinin 8 kanalını aynı anda ürettiği için **çıkışta da HWC tamponsuz**.
Kişi A'ya maliyeti: `x.permute(0,2,3,1).contiguous()`, tek satır, host tarafı — ağırlık
düzenine (ADR-011) dokunmuyor.

**Byte yerleşimi:** little-endian, dönüşümsüz.

```
mantıksal byte i    -> TDATA[8*(i mod 8) +: 8]
frame'in ilk byte'ı -> beat 0'ın TDATA[7:0]
INT8 two's complement, zero-point yok -> 0x80 = -128
```

> **`$readmemh` tuzağı** (ADR-009'un dosya köprüsünü doğrudan etkiler): `$readmemh` 64-bit
> diziye satır başına bir word okur ve en soldaki hex hanesi MSB'dir, yani mantıksal byte 7.
> Vektör script'i her 8 byte'lık grubu şöyle yazmalı:
> ```python
> f.write(f"{int.from_bytes(chunk, 'little'):016x}\n")
> ```
> Yanlışsa simülasyon "çalışır" ama her beat içinde byte'lar ters döner.

**Beat hizalaması — ADR-006'nın TKEEP değişmezi FC2'de kırılıyor:**

| Tensör | Byte | Beat | |
|---|---:|---:|---|
| Input `32×32×3` | 3072 | 384 | ✓ |
| Conv1 `28×28×6` | 4704 | 588 | ✓ |
| Pool1 `14×14×6` | 1176 | 147 | ✓ |
| Conv2 `10×10×16` | 1600 | 200 | ✓ |
| Pool2 `5×5×16` | 400 | 50 | ✓ |
| FC1 `120` | 120 | 15 | ✓ |
| **FC2 `84`** | **84** | **10,5** | ✗ |
| FC3 INT8 `10` | 10 | 1,25 | ✗ |
| FC3 INT32 bypass | 40 | 5 | ✓ |

Çözüm: **kanal boyutu 8'in katına sıfır dolgulanır** (FC2 → 88 B = 11 beat; ADR-002'nin tile
tablosu zaten 11 tile diyor). Maliyet 4 byte. Sıfır dolgu kanal boyutunda zararsız: sıfır
aktivasyon sıfır katkı verir, ağırlıkları da sıfır.

**Çıkış paketi — tam ağ, 48 byte / 6 beat:**

```
beat 0..4 : 10 × INT32 logit (little-endian, sınıf 0..9)   40 B
beat 5    : STATUS (32b) + RSVD (32b)                       8 B
            STATUS = [7:0] argmax [8] sat_seen [9] acc_ovf_seen [31:16] frame_id
TLAST = beat 5
```

INT32 logit tercihi iki gerekçeli: argmax karar noktasında clamp/eşitlik riski kalmıyor **ve**
40 B tam 5 beat (INT8 çıkışta 10 B = 1,25 beat, ADR-006 yine kırılırdı). Roadmap §4.4 zaten
"karşılaştırmalar sadece final sınıf üzerinde yapılmamalıdır" diyor. `frame_id` in-band: DMA
descriptor sırası karışırsa sessizce yanlış sınıf okunmasın. Perf sayaçları pakete konmuyor,
ADR-015'te register olarak var.

**Tek katman bring-up çıkışı:** Conv1 için `28×28×6 = 4704 B = 588 beat`, girişle aynı lane
konvansiyonu.

---

## Açık kalanlar

| # | Soru | Ne gerekiyor | Kimden |
|---|---|---|---|
| 1 | **Aşama 1'in bitiş hâli tek conv katmanı mı, tam ağ mı?** | Roadmap MVP'de ikisi de işaretsiz. Çok katmanlı ara aktivasyon düzeni (`[c_tile][H][W][8]` öneriliyor) buna bağlı | Ekip + danışman |
| 2 | AXI4-Lite yazma gecikmesi gerçekte kaç µs? | PYNQ'da bir kez ölçüm. `PARAM_SRC=1` yolunun aciliyetini belirler | Kişi B |
| 3 | `LAT = 3` mü 4 mü? | Sentez / timing | Kişi B |
| 4 | Requantizer başına DSP48E1 sayısı | Sentez. ADR-003 Tuzak 2: tahmin 2, varsayımla kesinleştirilmiyor | Kişi B |
| 5 | K-streaming mi K-chunking mi? | ADR-002 streaming öneriyor; tile-engine değişikliği | Kişi B |
| 6 | ADR-012 (runtime ağırlık yükleme), ADR-013 (skip connection) | Aşama 2 | Ekip |

## Kişi A tarafına düşen maddeler

1. `requant_ref()` taşmada hata fırlatmayacak, açık `wrap32` uygulayacak; önerilen imza
   `(y, sat, ovf)`.
2. `T_NUM_REQ_001` **pre-clamp `y_raw`** karşılaştıracak; boş tie listesi assertion'ı ve `n`
   süpürmesi (`n ∈ {0, 1, 16, 20, 24, 27, 31, 32}`) eklenecek.
3. Export'ta katman başına `assert abs(bias_q) + K*16384 <= 2**31 - 1`.
4. Export'ta `assert 1 <= n <= 49` (birincil kapı).
5. Aktivasyon beslemesi HWC: `x.permute(0,2,3,1).contiguous()`.
6. FC1 ağırlık permütasyonu (Soru 3'teki satır).
7. `s_y` kalibrasyonu pre-pool tensöründen.
8. Test vektör dosyaları `int.from_bytes(chunk, 'little')` ile yazılacak.

> **README senkronizasyon notu:** kök `README.md` hâlâ *"signed 50-bit requantization
> intermediates"* diyor ve *"n=0 and n=50…63 require explicit resolution with the RTL team"*
> ile *"MAC+bias overflow handling also need agreement"* maddelerini açık gösteriyor. Üçü de
> bu belgede kapandı (64-bit hesap yolu, tüm `n` tanımlı, wrap) — README güncellenmeli.
