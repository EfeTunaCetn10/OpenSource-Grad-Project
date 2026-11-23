---
title: ADR-019 Geometry Envelope ve Model Geometry Kararı
created: 2026-10-25
modified: 2026-10-25
type: decision
status: önerildi
tags: [dnn-accelerator, adr, kontrat, ml, model-geometry, co-design, bram, rtl]
---

# ADR-019: Geometry Envelope ve Model Geometry Kararı

## Durum
**Önerildi — 2026-10-25.** Emin'in onayı bekliyor. Tetikleyici: Kişi A'nın CompactCNN-v3
(32×32) ve v3-48 (48×48) ML sonuçları + v3 katmanlarının mevcut RTL üzerindeki layer-by-layer
bit-exact doğrulaması.

Bu ADR, [[ADR-002 CNN Topolojisi ve Dataset|ADR-002]]'nin "çözünürlük ancak doğruluk yetersiz
kalırsa artırılacak" maddesinin tetiklenmesine verilen cevaptır. ADR-002'yi geçersiz kılmaz;
Aşama 1 model geometry'sinin nasıl seçildiğini ve donanımın hangi geometry aralığını taahhüt
ettiğini ayırır.

## Karar

| # | Madde | Durum |
|---|---|---|
| 1 | Deliverable classifier LeNet-5 **değil**; Aşama 1 modeli hardware co-designed CompactCNN-v3 ailesidir | Öneri |
| 2 | LeNet-5 golden reference olarak regression'da **kalır**, silinmez | Türetilmiş |
| 3 | Contract'a giren şey tek bir input geometry değil, bir **geometry envelope**'dur | Öneri |
| 4 | 32×32 vs 48×48 seçimi envelope içinde **register + weight yükleme kararıdır**, RTL kararı değil | Öneri |
| 5 | 48×48'in resmi model olarak promote edilmesi Aşama 2 bitstream'inden **sonra**, ayrı kararla | Öneri |
| 6 | Systolic array büyütülmez (8×8, 64 DSP sabit) | Türetilmiş |
| 7 | 64×64 bugünkü register map'te **ifade edilemez**; envelope tavanı 48'dir | Ölçüldü |

### Geometry envelope (önerilen parametre taahhüdü)

| Parametre | Bugün | Envelope | Neden |
|---|---:|---:|---|
| `K_MAX` (compute_engine, layer_ctrl, weight_feeder) | 1024 | **2048** | v3-48 FC1 K=1152 > 1024; `K_W` 11→12 bit |
| `weight_feeder.DEPTH` | 8192 | **16384** | FC1 K=1152 için zorunlu alt sınır 9216 (aşağıda) |
| `act_buffer.OUT_H_MAX` / `OUT_W_MAX` | 28 | **48** | v3-48 conv1 çıkışı 48×48 |
| `act_buffer.C_TILE_MAX` | 2 | **4** | v3'te C_out=32 → 4 tile |
| `act_buffer.DEPTH` (64-bit word) | 784 | **4608** | 2 c_tile × 48 × 48 |
| `line_buffer` / `window_gen` `IN_W` / `IN_H` | 32 | **48** | — |
| `TILE_MAX` | 16 | 16 | v3 max 8 tile, LeNet FC1 15 — yeterli |

Envelope **declare edilip iki model geometry'siyle (32×32 ve 48×48) regression'dan geçirilir.**
O noktadan sonra iki model de aynı bitstream contract'ına oturur.

## Bağlam: ADR-002'nin tetiklenmiş şartı

ADR-002 iki şeyi önceden kayda geçirmişti:

1. *"Bu tablo Aşama 1'in **reference model** kontratıdır"* — LeNet-5'in işi datapath'i
   literatürde doğrulanmış bir golden reference ile sınamaktı, deliverable classifier olmak
   değil. `faz2-sim-e2e` üzerindeki 16/16 PASS bu işi bitirdi.
2. Çözünürlük için önceden tanımlı bir karar kuralı: *"önce renk (bedava), sonra gerekirse
   çözünürlük (maliyetli)... çözünürlük ancak doğruluk yetersiz kalırsa artırılacak"* — gerekçe
   de aynen şuydu: böcek türlerini ayıran bilgi renkte ve **ince dokuda**, 32×32 dokuyu yok
   ediyor.

Kişi A'nın 32→48 ölçümü bu hipotezi doğruladı. Yani 48×48 spekülatif bir deneysel aday değil,
**ADR-002'nin tetiklenmiş şartına verilen cevap.** Jüri karşısındaki anlamı da bu: karar
tahminle değil, önceden yazılmış bir kuralla verildi.

## Ölçümler (Kişi A, 2026-10-24/25)

Quantization contract değişmedi: signed INT8, zero-point 0, activation per-tensor scale,
weight per-output-channel scale, INT32 accumulation
([[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]).

| Model | Input | FP32 | INT8 | PTQ kaybı | macro recall (INT8) |
|---|---|---:|---:|---:|---:|
| v1 (bilinen ilk model) | 32×32 | — | ~%55.4 | — | — |
| CompactCNN-v3 | 32×32 | %61.44 | %60.77 | 0.68 pp | — |
| v3-48 (seed42) | 48×48 | %66.91 | %66.74 | **0.17 pp** | %52.82 |
| v3-48 (seed123) | 48×48 | %66.40 | — | — | — |
| v3-48-deep (seed42) | 48×48 | %69.00 | — | — | — |
| v3-48-deep (seed123) | 48×48 | %71.48 | %70.57 | 0.90 pp | %55.99 |

v3 operator seti: Conv + ReLU + MaxPool + FC. BatchNorm, residual, depthwise **yok** — mevcut
datapath'in dışına çıkan tek operator eklenmedi. Kanal sayıları 16/24/32, hepsi 8'in katı →
systolic array satır verimi %100, `ACTIVE_ROWS` maskeleme sadeleşiyor.

**İyi haber, kayda geçsin:** PTQ kaybı 0.17–0.90 pp. Quantization contract sağlam, **QAT'e
ihtiyaç yok.** ADR-003 doğru kurulmuş.

## Ayrıştırma: resolution sağlam, extra conv gürültüde

İki ML değişikliği aynı kefeye konmamalı:

| Değişiklik | Matched-seed kazanç | Modelin kendi seed spread'i | Hüküm |
|---|---:|---:|---|
| 32×32 → 48×48 | **+5.47 pp** (seed42), seed123 teyit ediyor (66.40) | 0.5 pp | **Sağlam** |
| +1 Conv 32→32 (deep) | +2.09 pp (seed42) | **2.48 pp** (69.00 vs 71.48) | Ayırt edilemez |

Extra conv'un kazancı o modelin kendi seed varyansından küçük. %71.48 şanslı seed; karar tabanı
~%69±2. Maliyeti +%33 cycle ve +9.2K parametre (85,314 → 94,562), compute 4.06M → 5.38M MAC.

**Karar: resolution alınır, extra conv ≥3 seed gösterene kadar beklet.** Hardware kararı 71.48
üzerine kurulmaz.

## RTL feasibility — kod okumasıyla ölçülen gerçekler

Kaynak: `faz2-sim-e2e` @ `2985e8e`, `systolic-array-8x8/rtl/`.

### 1. `weight_feeder.DEPTH = 8192` taşıyor — asıl blocker

ADR-011 adreslemesi `tile_idx*k_len + k`, bank başına `DEPTH = 8192` bayt:

| Katman | `k_len` | tile | max adres | Durum |
|---|---:|---:|---:|---|
| LeNet FC1 | 400 | 15 | `14×400+399 = 5999` | ✓ |
| v3-32 FC1 | 512 | 8 | `7×512+511 = 4095` | ✓ |
| **v3-48 FC1** | **1152** | **8** | **`7×1152+1151 = 9215`** | **✗ > 8191** |

Sorun ilk kez 48×48'de çıkıyor ve sessiz değil, bank sınırının dışına yazıyor. Alt sınır 9216;
power-of-2 için 16384 öneriliyor. BRAM: bank başına 64 Kb → 128 Kb, 8 bank → **16 → ~24-32
RAMB36**.

### 2. K'yi bölerek kaçış yolu yok

`compute_engine` her `start`'ta `CLEAR` state'inde accumulator'ları sıfırlıyor ve
**accumulate-continue portu yok** (ADR-018 K-streaming kararının doğal sonucu; harici
partial-sum tamponu bilinçli olarak yoktu). Yani FC1'i K=576+576 diye iki pass'e bölmek mümkün
değil — K tek pass'te sığmak zorunda. `DEPTH` maddesi bu yüzden pazarlık konusu değil.

### 3. `K_MAX = 1024` guard'lı

`compute_engine` (`k_len == 0 || k_len > K_MAX` → `config_error`) ve `weight_feeder` aynı
guard'ı taşıyor. Her yerde parameter; tek hard-coded yer `systolic_array_8x8.sv:33`
(`.K_MAX(1024)`) ve o bir convenience wrapper. 2048'e çıkmak `K_W`'yi 11→12 bit yapar.

### 4. `cfg_c_in` 9-bit bir blocker **değil** — düzeltme

Kişi A'nın endişesi gereksiz. FC'de `K = c_in × kh × kw` çarpımını factor'lemek yeterli:

```
1152 = 128 × 3 × 3   → c_in=128 (9 bit ✓), kh=3 (3 bit ✓), kw=3 (3 bit ✓)
 512 = 128 × 2 × 2   → aynı şekilde (c_in alanı 0..511, 512 doğrudan sığmaz)
```

`A_LAYER_CFG` layout'u bozulmadan 1152 ifade edilebiliyor. Önerilen `A_K_LEN @ 0x018` fikri
doğru ve 0x018 gerçekten boş (`A_TILE_CFG=0x014` → `A_PARAM_BASE=0x040` arası), `cfg_k_len`
zaten ayrı 16-bit register ve yalnız kaynağı `A_COMMIT`'te çarpıma bağlı. Ama bu bir
**okunabilirlik** kazancı (fake kh/kw yazmaktan kurtulmak), zorunluluk değil. Yapılacaksa
[[ADR-015 Register Map ve Parametre Yükleme|ADR-015]] revizyonu olarak yapılır.

### 5. Gerçek tavan: `cfg_out_h` / `cfg_out_w` 6-bit

`layer_cfg_reg[24:19]` ve `[30:25]` → max **63**. 48 sığıyor, **64 sığmıyor.** ADR-002'nin
"64×64 için kapı açık" ifadesi bugünkü register map'te **geçerli değil**; 64×64 bir register
map revizyonu gerektirir. Envelope tavanı bu yüzden 48.

### 6. Bozulmayanlar

- **AXI frame:** 48×48×3 = 6912 B = tam **864 beat** (64-bit TDATA). Kalansız →
  [[ADR-006 AXI Stream Paket Semantiği|ADR-006]] değişmiyor, TKEEP hâlâ sabit all-1.
- **Systolic array / PE:** `systolic_array_os.sv`, `pe_os.sv` dokunulmuyor.
- **Requant contract:** ADR-014 değişmiyor; pooling scale/zero-point değiştirmiyor.
- **Activation layout:** ADR-018 padded tile-major `[c_tile][H][W][8]` korunuyor; Kişi A'nın
  `tile_major_repack.sv`'si bu layout'un üstünde çalışıyor.

## Maliyet

| Kaynak | v3-32 | v3-48 | Bütçe (xc7z020) |
|---|---:|---:|---:|
| DSP48E1 | 64 | **64** | 220 |
| BRAM — weight bank | ~16 | ~24-32 | — |
| BRAM — act_buffer (ping-pong) | ~8 | ~18 | — |
| BRAM toplam (kaba) | **~24** | **~50** | 140 |
| Ağırlık (bayt) | 44.3 K | 94.6 K | — |
| Conv1 çıkış tamponu | 16,384 B | 36,864 B | — |

Latency tahmini (start başına ~24 cycle pipeline overhead varsayımıyla, @100 MHz):

| Model | cycle | süre | FPS |
|---|---:|---:|---:|
| v3-32 | ~41 K | 0.41 ms | ~2400 |
| v3-48 | ~98 K | 0.98 ms | ~1020 |
| v3-48-deep | ~128 K | 1.28 ms | ~780 |

> [!warning] Bu sayılar tahmin, ölçüm değil. Start başına gerçek overhead `A_CYCLE_COUNT` ile
> ölçülmeli. Not: conv1'de K=27 (3×3×3) olduğu için sabit overhead cycle'ların ~%47'sini
> yiyor — 3×3 first layer'ın görünmeyen bedeli bu. Düzeltmesi RTL'de back-to-back tile
> issue'su, ama **önce ölç**.

## Gerekçe

### Neden envelope, neden "48×48 yeni contract" değil

- **Takvim.** Aşama 1 son tarihi 30 Eylül 2026 (Abstract §49), bugün 25 Ekim — gecikmiş.
  Aşama 2 (karta implementasyon) **ve** Aşama 3 (RFF) ikisi de 31 Aralık 2026, yani ~9.5 hafta.
  Tezin nihai iddiası (Abstract §85) RFF uygulaması. Bu tabloda entegrasyonu 48×48 ile baştan
  koşturmak yanlış yatırım.
- **48×48 işinin değerli kısmı model değil, generalization.** `K_MAX`, `W_DEPTH` ve buffer
  sınırlarının geometry'den bağımsız hale gelmesi Aşama 3'ün kritik yolunda: Jian et al.
  yaklaşımı (1D conv, ham IQ) uzun K üretir, spectrogram yolu 32×32'den büyük frame üretir.
  Yani bu iş RFF için zaten yapılacak — böcek accuracy'si onun yan ürünü.
- **Karar geciktirme değeri.** Envelope declare edilince 32 vs 48 seçimi tez yazarken elindeki
  accuracy'ye göre yapılır ve RTL churn'ü sıfır olur.
- **Latency bütçesi boş.** 220 DSP'nin 64'ü kullanılıyor, WNS +3.074 (post-route, conv1_top).
  3× latency artışı anlamsız bir maliyet. Projenin kıt kaynağı accuracy, latency değil — bu
  asimetri 48×48'i satın alınabilir yapan şey. **Array büyütülmez; o yöne kaynak harcanmaz.**

### Jüri argümanı

> *"Donanımı tek bir modele göre sabitlemedik. Bir geometry envelope declare ettik ve iki farklı
> model geometry'sini (32×32 ve 48×48) aynı bitstream contract'ı üzerinde bit-exact doğruladık.
> Aşama 1'de LeNet-5 golden reference ile datapath'in doğruluğunu kanıtladık; deliverable
> classifier'ı ise donanımın kendi kısıtlarından türettik — kanal sayıları 8×8 array'in satır
> sayısının katları (16/24/32), operator seti datapath'in desteklediğiyle sınırlı."*

Bu, "kanallar 8'in katı olsun" argümanından güçlü — o argüman v3'te **zaten sağlanıyor**, yani
tek başına bir karar değil.

## Sonuçlar

- [ ] **Kişi A'ya giden iş:** `W_DEPTH` taşması bildirilecek + pool-before-FC deneyi istenecek
      → `2026-10-25 Kişi A — v3-48 Feasibility Düzeltmeleri ve İstenen Deney.md`
- [ ] 32×32 full-network entegrasyon + bitstream kapanacak (Aşama 2) — geometry'den bağımsız iş
- [ ] Paralelde envelope genişletmesi yapılacak, regression **hem 32×32 hem 48×48** ile koşacak
- [ ] `A_CYCLE_COUNT` ile start başına gerçek overhead ölçülecek
- [ ] **Accuracy pass bar sayı olarak yazılacak.** Abstract §22 "düşük performanslı, kullanışsız
      tasarım kabul edilmez" diyor ama sayı vermiyor; sayı olmadan ML hattı sonsuza tırmanır ve
      Aşama 2/3 takvimi yanar.
- [ ] Final accuracy **hiç model seçiminde kullanılmamış** bir test set'ten verilecek
- [ ] ADR-002'ye "Aşama 1 modeli v3 ailesi, LeNet-5 reference olarak kalıyor" notu düşülecek
- [ ] ADR-015: `A_K_LEN @ 0x018` opsiyonel madde olarak kaydedilecek (zorunlu değil)
- [ ] ADR-012 (runtime weight loading): v3-48 toplam ağırlığı 94.6 KB > 64 KB bank kapasitesi →
      **katman başı reload zorunlu.** Roadmap bunu Aşama 3 önkoşulu sayıyordu; 48×48'de Aşama 1
      önkoşulu oluyor.

### Metodoloji uyarısı

- Bütün accuracy sayıları **validation** accuracy, ve mimari + best epoch (48) aynı validation
  üzerinde seçildi. v1 → v3 → v3-48 → v3-48-deep merdiveninin bir kısmı validation'a overfit.
  Final sayı seçimde kullanılmamış bir test set'ten gelmeli, bir kez.
- macro recall accuracy'nin ~15 pp altında (%55.99 vs %70.57) → dataset dengesiz, bazı sınıflar
  büyük olasılıkla ölü. Per-class recall + confusion matrix olmadan "%70" bir şey söylemiyor.
- **Class-balanced loss / resampling donanım maliyeti sıfır** ve extra conv'dan büyük kazanç
  verebilir. Masada kalan en ucuz accuracy orada.

## Kararı geçersiz kılacak kanıt

- Pool-before-FC deneyi (FC1 K=288) accuracy'yi korursa: `K_MAX` ve `W_DEPTH` değişikliği
  **gereksizleşir**, envelope yalnız buffer sizing'e iner. Bu durumda 48×48 promotion'ı daha
  erken ve daha ucuz yapılabilir.
- Test set üzerinde 48×48'in avantajı ≤2 pp'ye düşerse: envelope genişletmesi yapılır (RFF için
  gerekli) ama Aşama 1 modeli 32×32'de kalır.
- 3 seed sonrası extra conv ≥3 pp tutarlı kazanç verirse: deep varyant resmi aday olur, latency
  bütçesi hâlâ rahat.
- Danışman RFF temsilini ham IQ (1D conv) olarak sabitlerse: 48×48 2D geometry'si Aşama 3'e
  taşınmaz, envelope'un değeri yalnız K genişliğinde kalır — o zaman `OUT_*_MAX` genişletmesi
  Aşama 1'e özel bir masraf olur ve yeniden tartışılır.

---
**Doğrulama notu:** RTL sayıları `faz2-sim-e2e` @ `2985e8e` üzerinde kod okumasıyla çıkarıldı,
simülasyonla teyit edilmedi. Latency satırları tahmin. ML sayıları Kişi A'nın raporundan
alındı, bağımsız doğrulanmadı.
