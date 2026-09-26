---
title: ADR-018 K-Streaming ve Ara Aktivasyon Düzeni
created: 2026-09-26
modified: 2026-09-26
type: decision
status: önerildi
tags: [dnn-accelerator, adr, kontrat, rtl, dataflow, bram, memory-layout]
---

# ADR-018: K-Streaming Compute Engine ve Çok Katmanlı Ara Aktivasyon Düzeni

## Durum
**Önerildi — Kişi B onayı bekliyor (2026-09-26).**

İki bağlı karar. Aşama 1'in bitiş hâli **tam ağ** olarak kesinleşince
([[ADR-017 Simülasyon ve Emülasyon Ortamı|ADR-017]] Sonuçlar, 2026-09-26)
[[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]'nın "Açık kalan" maddesi
kilitlenebilir hâle geldi; onu kilitlemek de K'nin nasıl indirgendiğine bağlı.

| Madde | Durum |
|---|---|
| K-streaming (chunk'lama değil) | **Türetilmiş** — ADR-014 `k_last`, ADR-002 tile notu |
| `systolic_array_os.sv` ve `pe_os.sv` değişmiyor | **Türetilmiş** — bugünkü koşan testler korunuyor |
| A-left = ağırlık, B-top = aktivasyon | **Türetilmiş** — ADR-011 banking'den |
| `[c_tile][H][W][8]` tile-major HWC | Onay bekliyor |
| Ping-pong ara tampon, iki adet 8 KB | Onay bekliyor |
| FC'de kolon ekseni ölü — Aşama 2'ye park | Onay bekliyor |

## Karar 1 — K-streaming

`K` indirgemesi tek `start` boyunca **akış** olarak yapılır. Output-stationary
accumulator'lar tüm `K` boyunca PE içinde kalır; `k_last` tek sayaç karşılaştırmasıdır.
Harici partial-sum tamponu **yoktur**.

### Neden `K_MAX=8` bir mimari sınır değil, harness artefaktı

Mevcut `systolic_tile_engine.sv` tüm tile'ı register'a alıyor
(`a_tile_reg` = `ROWS*K_MAX*8` bit, `b_tile_reg` = `K_MAX*COLS*8` bit) ve her `start`'ta
accumulator'ları temizliyor. `K_MAX=8` tavanı **bu register'lardan** geliyor —
output-stationary dataflow'un kendisinden değil. Accumulator zaten PE'nin içinde yaşıyor;
kenar akışları cycle başına besleniyor. Tile register'ları kaldırılıp kenarlar streaming
kaynaklardan sürülünce `K` sınırsız kalır.

`K`'nin gerçek sınırı bellek değil aritmetiktir:
[[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün INT32 wrap penceresi ve export edilen her
`bias_q` için `|bias_q| + K·16384 ≤ 2^31-1` yeter koşulu. `K=400`'de bu
`|bias_q| ≤ 2^31-1 - 6.553.600` demek — bol marj.

### Neden chunk'lama elendi

| | K-chunking (`K_MAX=8`) | K-streaming |
|---|---|---|
| LeNet verimi | %17,6 | %48 |
| Harici INT32 partial-sum tamponu | gerekli | **yok** |
| FC1'de requant tetikleme | 50 chunk × 15 tile = **750** | 15 |
| `k_last` mantığı | chunk sayacı + tampon adresleme | tek sayaç |
| Taşma bayrağı davranışı | indirgeme sırasına bağlı | sıradan bağımsız |

[[ADR-014 Requantizer Port ve Zamanlama Sözleşmesi|ADR-014]]'ün kapattığı sessiz hata
sınıfı doğrudan chunk'lamadan doğuyordu: her chunk kendi içinde geçerli bir INT8 üretir,
hiçbir bayrak yanmaz, sonuç sessizce çöp olur. Streaming o sınıfı **yapısal olarak**
ortadan kaldırıyor — kapatmakla uğraşmak yerine.

### Korunan ve değişen

**Değişmiyor:** `rtl/pe_os.sv` ve `rtl/systolic_array_os.sv`. İkisi de zaten cycle başına
kenar akışı + `step` enable arayüzüne sahip; `K` kavramını hiç bilmiyorlar. 2026-09-26'da
XSim'de geçen `tb_pe_os` ve `tb_systolic_array_8x8` testleri **aynen geçerli kalıyor** —
bu kararın bedeli doğrulanmış çekirdeği çöpe atmak değil.

**Değişiyor:** `systolic_tile_engine.sv` retire edilir (baştan beri demo harness'tı) ve
yerine streaming bir `compute_engine` gelir. 64-geniş paralel tile portları kaybolur.
`systolic_array_8x8.sv` (OOC sentez top'u) 64 DSP48 iddiasını koruyan yeni bir top ile
değiştirilir.

### Kenar eşlemesi — yanlış bağlanmaya açık, bu yüzden yazılı

`M = çıktı kanalı` (satır), `N = çıktı pozisyonu` (kolon), `K = indirgeme`:

```
A-left  (satır kenarı, 8 akış) = AĞIRLIK     <- 8 BRAM bankası, bank = c_out mod 8
B-top   (kolon kenarı, 8 akış) = AKTİVASYON  <- window generator, 8 çıktı pozisyonu
```

[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] "8 banka, her banka bir array satırına
(çıktı kanalı grubuna) özel" diyor — yani ağırlık satır kenarından girer. Mevcut RTL'in
`a_matrix`/`b_matrix` isimleri nötr olduğu için bu ters bağlanabilir ve **fonksiyonel
olarak sessizce yanlış** sonuç verir (transpoze edilmiş çarpım). Sözleşme yukarıdaki
dört satırdır.

### Skew artık shift register

Mevcut harness skew'i `run_cycle`'dan kombinasyonel indeks hesabıyla üretiyor. Streaming'de
skew üçgen bir gecikme bankasına döner: satır `r`'nin ağırlık akışı `r` cycle, kolon `c`'nin
aktivasyon akışı `c` cycle geciktirilir (derinlik 0..7). ADR-011'in "`t` ve `k` tüm 8
bankaya aynı cycle'da aynı adres" kararıyla uyumlu: bankalar `k`'yi eşzamanlı verir, skew
array girişinde uygulanır.

## Karar 2 — Ara aktivasyon düzeni

**`[c_tile][H][W][8]`** — tile-major HWC, kanal ekseni 8'in katına sıfır dolgulu.
[[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]'nın önerdiği düzen aynen
kabul edildi; gerekçesi (HWC line buffer'da 65× daha ucuz, çıkışta tamponsuz) orada.

**Girdi frame'i bu düzenin tek-tile, dolgusuz özel hâlidir** — `32×32×3`, 3072 B, 384 beat,
dolgu yok (ADR-016 §1). Dolgu yalnız PL içi ara tamponlara uygulanır, DMA ile gelen girdiye
uygulanmaz. Window generator'ın `c_in` parametresi bu iki durumu zaten ayırıyor.

### Ara tensör boyutları (dolgulu)

| Tensör | Mantıksal | `c_tile` | Dolgulu byte |
|---|---|---:|---:|
| Input `32×32×3` | 3072 | 1 (dolgusuz) | **3072** |
| Conv1 `28×28×6` | 4704 | 1 | 6272 |
| Pool1 `14×14×6` | 1176 | 1 | 1568 |
| Conv2 `10×10×16` | 1600 | 2 | 1600 |
| Pool2 `5×5×16` | 400 | 2 | 400 |
| FC1 `120` | 120 | 15 | 120 |
| FC2 `84` | 84 | 11 | 88 |
| FC3 INT32 bypass | 40 | — | 40 |

Her satır 8'e tam bölünüyor — [[ADR-006 AXI Stream Paket Semantiği|ADR-006]]'nın
"TKEEP fonksiyonel olarak sabit all-1" değişmezi ayakta kalıyor. FC2'nin `84 → 88`
dolgusu ADR-016'nın bulgusunun uygulanmış hâli.

### Ping-pong tampon

Katman `N`'in girdisi okunurken `N+1`'in çıktısı yazılır; convolution çok satırlık pencere
okuduğu için **yerinde (in-place) yazma güvenli değil**. İki tampon, her biri en büyük ara
tensöre (6272 B) yuvarlanmış **8 KB** → toplam **16 KB**.

Zynq-7020 BRAM bütçesi 140 × 36 Kb = **630 KB**. Ara tampon %2,5. Ağırlıklar
(`450 + 2400 + 48000 + 10080 + 840 ≈ 61.770` INT8 ≈ 60 KB, banka başına ≈ 7,7 KB) %10.
[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] "BRAM bütçesinde sorun yok" diyordu; sayı
bu, ve FC1 tek başına ağırlık belleğinin %78'i.

## Bilinen verimsizlik — FC'de kolon ekseni ölü, Aşama 2'ye park

`batch = 1` olduğu için FC katmanlarında `N = 1`: 8 kolondan biri çalışır, 64 PE'nin 8'i
aktiftir. Conv'da sorun yok (conv1'de `N = 784`).

Çözüm K-split + adder tree: `K`'yi 8 kolona bölüp kısmi toplamları ağaçla toplamak.
K-streaming ile birlikte verim %70'e, frame süresi ~146 µs'ye iner. **Aşama 1'e
alınmıyor** — doğruluk önce, ve engine'in `active_cols` yolu bu modu sonradan kabul edecek
şekilde parametrik bırakılıyor. Aşama 1'de FC'ler doğru ama yavaş çalışır.

> [!warning] Bu, ertelenirse RTL'i baştan yazdıran türde bir madde değil — `active_cols`
> parametrik kaldığı sürece eklenebilir. Ama parametrik kalmazsa yazdırır.

## Alternatifler

- **K-chunking + harici partial-sum tamponu:** yukarıdaki tablo. Elendi.
- **PE'ye `acc_seed`/`load_seed` yolu ekleyip chunk'ları PE içinde birleştirmek:**
  `pe_os.sv`'yi ve bugün geçen testleri değiştirir, üstelik streaming ile aynı sonucu daha
  fazla kontrol karmaşıklığıyla verir. Elendi.
- **CHW ara düzen:** ADR-016'da ölçüldü, 65× tampon. Elendi.
- **Tek tampon, in-place yazma:** convolution penceresi henüz okunmamış satırları ezer.
  Elendi.

## Sonuçlar

- `systolic_tile_engine.sv` ve `systolic_array_8x8.sv` retire edilir; yerine streaming
  `compute_engine` + yeni OOC top gelir. `pe_os.sv` / `systolic_array_os.sv` korunur.
- [[ADR-002 CNN Topolojisi ve Dataset|ADR-002]]'nin tile tablosundaki "micro-run" sütunu
  yeniden hesaplanmalı: `K` chunk'lanmadığı için output-tile invocation sayısı kalıyor
  (conv1 98, conv2 26, FC1 15, FC2 11, FC3 2), `K` chunk sütunu düşüyor.
- [[ADR-014 Requantizer Port ve Zamanlama Sözleşmesi|ADR-014]]'ün `in_k_last`'ı tek sayaç
  karşılaştırmasından gelir; ADR-014'ün "dış partial-sum toplayıcısı da taşma tespitine
  dahil olmalı" maddesi **düşer** — dış toplayıcı yok.
- Yeni test kimlikleri: `T_ENG_KSTREAM_001` (K=75/150/400 için golden karşılaştırma),
  `T_ENG_SKEW_001` (skew shift register'ının doğru hizalaması),
  `T_MEM_PINGPONG_001` (katman sınırında tampon takası, okuma/yazma çakışması yok).
