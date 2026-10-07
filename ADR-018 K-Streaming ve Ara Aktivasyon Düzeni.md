---
title: ADR-018 K-Streaming ve Ara Aktivasyon Düzeni
created: 2026-09-26
modified: 2026-10-07
type: decision
status: önerildi
tags: [dnn-accelerator, adr, kontrat, rtl, dataflow, bram, memory-layout]
---

# ADR-018: K-Streaming Compute Engine ve Çok Katmanlı Ara Aktivasyon Düzeni

## Durum
**Karar 1 (K-streaming): türetilmiş ve implemente edildi.**
**Karar 2 (ara aktivasyon düzeni): fiziksel layout 2026-10-07'de kilitlendi — padded
tile-major.** Gerekçe, bedeli ve kararı geçersiz kılacak kanıt aşağıdaki
"Ek madde — 2026-10-07" bölümünde. Kalan onay bekleyen madde yalnız FC'de kolon ekseninin
Aşama 2'ye parkıdır.

İki bağlı karar. Aşama 1'in bitiş hâli **tam ağ** olarak kesinleşince
([[ADR-017 Simülasyon ve Emülasyon Ortamı|ADR-017]] Sonuçlar, 2026-09-26)
[[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]'nın "Açık kalan" maddesi
kilitlenebilir hâle geldi; onu kilitlemek de K'nin nasıl indirgendiğine bağlı.

| Madde | Durum |
|---|---|
| K-streaming (chunk'lama değil) | **Türetilmiş** — ADR-014 `k_last`, ADR-002 tile notu |
| `systolic_array_os.sv` ve `pe_os.sv` değişmiyor | **Türetilmiş** — bugünkü koşan testler korunuyor |
| A-left = ağırlık, B-top = aktivasyon | **Türetilmiş** — ADR-011 banking'den |
| `[c_tile][H][W][8]` tile-major HWC | **Kabul edildi (2026-10-07)** |
| Ping-pong ara tampon, iki adet 8 KB | **Kabul edildi (2026-10-07)** |
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

## Ölçüm — 2026-09-26, implementasyon sonrası

`compute_engine` yazıldıktan sonra iki farklı verim rakamı ortaya çıktı ve **ikisi de doğru
ama farklı şeyi ölçüyor.** Karıştırılmaması için ikisi de burada:

**1. Engine'in kendi verimliliği (tek tam 8×8 tile, `K=400`):** 400 besleme + 14 skew/flush +
8 drain + 1 setup = **423 cycle**, yani 400 üretken cycle'a karşılık 23 cycle overhead →
**%96,6 MAC-slot kullanımı.** Bu, streaming engine'in neredeyse hiç overhead'i olmadığını
söylüyor ve tasarımın kalitesini ölçüyor.

**2. Ağ seviyesi verim (tüm LeNet-5, ilk ilkelerden hesap):**

| Katman | `M×N×K` | Tile | Cycle/tile | Toplam cycle | Faydalı MAC | Verim |
|---|---|---:|---:|---:|---:|---:|
| Conv1 | `6×784×75` | 98 | 96 | 9.408 | 352.800 | %58,6 |
| Conv2 | `16×100×150` | 26 | 173 | 4.498 | 240.000 | %83,4 |
| FC1 | `120×1×400` | 15 | 409 | 6.135 | 48.000 | **%12,2** |
| FC2 | `84×1×120` | 11 | 129 | 1.419 | 10.080 | **%11,1** |
| FC3 | `10×1×84` | 2 | 93 | 186 | 840 | **%7,1** |
| **Toplam** | | **152** | | **21.646** | **651.720** | **%47,0** |

Cycle/tile = `K + (rows-1) + (cols-1) + cols_drain + 1`.

**Frame süresi: 21.646 cycle = 216 µs @ 100 MHz.**

Bu, bu ADR'nin yukarıda chunk'lama karşısında öne sürdüğü **%48** rakamını bağımsız olarak
doğruluyor. İkinci rakamın birincisinden düşük olmasının sebebi engine değil, FC'de
`N = 1` olması — 64 PE'nin 8'i çalışıyor.

> **Rakamları karıştırma:** %96,6 "engine tam tile'da ne kadar verimli", %47,0 "bu ağ bu
> engine'de donanımın ne kadarını kullanıyor". Biri tasarım kalitesi, diğeri iş yükü uyumu.

**FC'nin gerçek maliyeti sayıyla:** FC1+FC2+FC3 = 7.740 cycle, yani **zamanın %35,8'i**, ve
karşılığında toplam MAC'in yalnız **%9,0'ı**. Aşağıdaki K-split maddesinin iş gerekçesi tam
olarak bu satır.

### Bir yan bulgu — MAC accumulation'da INT32 wrap pratikte imkânsız

`compute_engine`'in wrap testi `K = 131.073` gerektirdi. Sebebi aritmetik: INT8×INT8 çarpımın
maksimum büyüklüğü `128 × 128 = 16.384`, dolayısıyla `K` uzunluğunda indirgeme en fazla
`K × 16.384` büyüklüğe çıkar. `2^31 - 1` sınırını aşmak için `K > 131.071` gerekiyor —
gerçek ağın en büyük `K` değeri **400**.

Yani [[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün wrap kaygısı MAC indirgemesinden değil
**bias toplamasından** doğuyor; `|bias_q| + K·16384 ≤ 2^31-1` yeter koşulunun bağlayıcı olan
yarısı `bias_q` tarafı. Accumulator wrap'i Aşama 1'de erişilemez bir durum — ama testi
silmeye gerek yok, `K_MAX` parametrik olduğu için doğrulama-amaçlı büyük `K` ile koşuyor.

## Bilinen verimsizlik — FC'de kolon ekseni ölü, Aşama 2'ye park

`batch = 1` olduğu için FC katmanlarında `N = 1`: 8 kolondan biri çalışır, 64 PE'nin 8'i
aktiftir. Conv'da sorun yok (conv1'de `N = 784`).

Çözüm K-split + adder tree: `K`'yi 8 kolona bölüp kısmi toplamları ağaçla toplamak.
K-streaming ile birlikte verim %70'e, frame süresi ~146 µs'ye iner. **Aşama 1'e
alınmıyor** — doğruluk önce, ve engine'in `active_cols` yolu bu modu sonradan kabul edecek
şekilde parametrik bırakılıyor. Aşama 1'de FC'ler doğru ama yavaş çalışır.

> [!warning] Bu, ertelenirse RTL'i baştan yazdıran türde bir madde değil — `active_cols`
> parametrik kaldığı sürece eklenebilir. Ama parametrik kalmazsa yazdırır.

## Ek madde — 2026-09-26: window generator bağlanınca çıkan üç madde

`line_buffer.sv` + `window_gen.sv` yazılıp `compute_engine`'e bağlandığında (ilk gerçek
convolution, golden ile doğrulandı, 6/6) üç şey ortaya çıktı.

### 1. `k` sırası ölçüldü — ADR-011'in vaadi bedava ayakta

Aktivasyonlar HWC saklandığı için `k`'nin **spatial-major** (`ci` en hızlı,
`k = (kh·kW + kw)·c_in + ci`) sıralanması bellekte daha doğal görünüyordu; bu sıra seçilseydi
[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]'in "conv ağırlıklarında permütasyon yok" vaadi
düşer ve [[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]] §5'in FC1 bulgusunun
conv kopyası doğardı.

**Ölçüldü: spatial-major hiçbir kazanç vermiyor** — 0 byte, 0 BRAM portu, 0 stream cycle.
Yalnızca adres sıralamasını değiştiriyor. Dolayısıyla ADR-011'in kanal-major sırası
(`k = ci·(kH·kW) + kh·kW + kw`) korunuyor ve **conv ağırlık export'u permütasyonsuz kalıyor.**
Bu artık bir tercih değil, ölçülmüş bir sonuç.

### 2. Kısmi son kolon grubu — sessiz hata sınıfı, kapatıldı

`out_W` 8'in katı değil (conv1 = 28, conv2 = 10, pool çıkışları 14 ve 5), yani her çıktı
satırının **son kolon grubu kısmi**. `active_cols` conv1'de `8/8/8/4`, conv2'de `8/2` olarak
sürülmeli ve kullanılmayan lane'ler sıfır olmalı. Yanlış yapılırsa her çıktı satırının son
birkaç pikseli çöp olur ve **çıktıya bakarak anlaşılmaz** — tensör doğru şekilde, doğru
boyutta ve çoğu doğru değerle gelir. Kabul testine yazıldı.

### 3. Açık kalan — generator ↔ engine metadata sözleşmesi (WP8'i bloke eder)

Bu ADR ve ADR-016, window generator'ın **tile-start / row-group metadata**'sını ve
`compute_engine` ile backpressure eşleşmesini tanımlamıyor. Şu an testbench bunları elle
sürüyor; layer sequencer yazılırken kimin `start`'ı ürettiği, `active_cols`'un hangi cycle'da
geçerli olduğu ve satır grubu sınırının nasıl bildirildiği sözleşme olmak zorunda.

Ayrıca [[ADR-005 Direct Convolution|ADR-005]] padding desteğinden söz ediyor ama **sınır
cycle sözleşmesini** tanımlamıyor. Aşama 1 valid convolution (`pad = 0`) olduğu için bu
bloke etmiyor; `pad` parametresi RTL'de duruyor ama sıfırdan farklı değer için sınır
davranışı yazılı değil.

> Bu üç maddenin ilk ikisi kapandı, üçüncüsü **WP8'in önkoşulu.**

## Ek madde — 2026-10-07: Karar 2'nin fiziksel layout'u kilitlendi

Üç seçenek (dense HWC / padded tile-major / tile-major store + dense gather adapter) ADR
ve RTL kaynakları üzerinden karşılaştırıldı; seçilen **padded tile-major**:

```
addr = (((c_out >> 3)*H + h)*W + w)*8 + (c_out & 7)
```

### Neden

- `requant_array` beat'i fiziksel word ile birebir: lane `r` → `addr_base + r`, mask dışı
  lane sıfır. **Tek aligned 64-bit write, bir port, bir cycle.** Dense HWC'de Conv1 beat'i
  6 valid byte taşır; başlangıç offset'leri `0,6,4,2` olduğu için beat'lerin yarısı word
  crossing yapar ve single-port direct implementation'da worst-case 2 cycle/beat eder.
- Her physical row/tile plane 8-byte katı (Conv1 ve Pool1 dahil), FC2 `84 → 88 B`. Yani
  [[ADR-006 AXI Stream Paket Semantiği|ADR-006]]'nın `TKEEP` all-1 değişmezi **istisnasız**
  korunuyor. Dense HWC'de FC2'nin 84 byte'ı bu değişmezi kırıyor.
- Exact ping-pong `2 × 6272 = 12.544 B`; kapasite `140 × 36 Kb = 645.120 B` üzerinden
  **%1,94**, bu ADR'nin yuvarladığı 16 KB allocation ise %2,54. Dense HWC'den fark
  `13.160 − 11.196 = 1.964 B`, yani tasarruf kararı değiştirecek büyüklükte değil.
- Aşama 2'nin FC K-split'i için her physical word doğrudan sekiz `K` lane veriyor.
- Alternatif 3 (gather adapter) aynı write tarafını veriyor ama Aşama 1'e padding strip +
  64-bit repack + FIFO + backpressure taşıyan yeni bir stateful blok ekliyor; bit-exact
  doğruluk hedefinde en büyük verification surface o.

### Bedeli — dördü de açık uç, gizlenmiyor

1. `line_buffer` / `window_gen` arayüzüne **`C_LOGICAL` ve `C_PHYS_STRIDE` ayrımı** şart.
   Conv1 input `3/3`, Conv2 input `6/8`. `K_LEN` yalnız `C_LOGICAL`'dan hesaplanmalı;
   `C_PHYS` ile hesaplanırsa `K` 150 yerine 200 olur, output shape doğru kalır, değerler
   sessizce yanlış olur ve hiçbir bayrak yanmaz.
2. **Bu ADR'nin kendi iddiası yanlıştı, düzeltiliyor.** Yukarıdaki "Window generator'ın
   `c_in` parametresi bu iki durumu zaten ayırıyor" satırı mevcut RTL için geçerli değil:
   `line_buffer` tek bir `C_IN`'i hem physical row size (`ROW_BYTES = IN_W*C_IN`,
   `TOTAL_BYTES`) hem logical read index (`col*C_IN + ch`) için kullanıyor. Değiştirilmemiş
   hâliyle 1568 byte'lık physical Conv2 frame'inin ilk 1176 byte'ını yanlış `(row,col,ch)`
   olarak tüketir ve erken `frame_done` verir.
3. Conv2 ingest `1176 → 1568 byte`. Bu bir performans ölçümü değil, byte-serialized
   writer'ın loop sayısı farkı.
4. **FC1 export'u [[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]'nın
   one-liner'ı DEĞİL.** Physical sıra `[c_tile][h][w][lane]`, plain `[h][w][c]` ile aynı
   değil; `H=W=5, C=16` için `c=8,h=1,w=0` dense HWC'de 88, tile-major'da 240'a düşüyor.
   Doğru transform:

   ```python
   w_fc1 = w_fc1.reshape(120, 2, 8, 5, 5).permute(0, 1, 3, 4, 2).reshape(120, 400)
   ```

   Conv ağırlık export'u **değişmiyor**: [[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]'in
   `k = ci*(kH*kW) + kh*kW + kw` reduction order'ı ve "conv'da permütasyon yok" vaadi
   ayakta. Storage layout ile reduction order aynı şey değil; physical layout'u gerekçe
   gösterip `k`'yi spatial-major yapmak o vaadi bozar.
5. Input `C > 8` olan gelecek bir conv layer'da `[c_tile][H][W][8]` stream mevcut row-ring'e
   bütün kanalları aynı anda getirmiyor. K-streaming korunacaksa full-buffer gather veya
   line-buffer redesign gerekir — **Aşama 2 blocker'ı olarak kaydedildi.**

### Yapılacaklar

- `line_buffer`/`window_gen`'e `C_LOGICAL` / `C_PHYS_STRIDE` ayrımını ekle.
- Intermediate writer adresini yukarıdaki formülle kilitle; inactive lane'leri sıfır yaz ve
  "bir word, bir cycle" assertion'ı koy.
- `model/window_ref.py`'ye ayrı physical tile-major buffer modeli ekle; padding byte'larını
  **nonzero sentinel** yapıp engine'e yine tam `K = 150` beat gittiğini kanıtla.
- Kişi A'ya FC1 transform'unu bildir; `.coe` için one-hot order regression ekle.
- Yeni test kimlikleri: `T_LAYOUT_ADDR_001` (coordinate-coded round-trip, `188`/`250`
  checkpoint'i normative vektör), `T_CONV2_REPLAY_001` (nonzero padding sentinel + 150-beat
  assertion), `T_FC1_ORDER_001` (one-hot weight/activation).

### Bu kararı geçersiz kılacak şey

İki parametreli read path'in BRAM inference'ını veya timing'ini bozduğunu gösteren bir
post-synthesis/XSim kanıtı; ya da dense compaction packer'ın full-rate, `TKEEP` all-1 ve
tüm katmanlarda tek kontratla daha az RTL/state ile geçtiğinin gösterilmesi. Ayrıca Aşama
1 kapsamına input `C > 8` olan bir conv layer girerse Option 2'nin row-ring avantajı biter
ve gather adapter yeniden değerlendirilmelidir.

### Yukarıdaki "Ek madde — 2026-09-26" maddesi 3 kapandı

Generator ↔ engine metadata sözleşmesi artık testbench'in elle sürdüğü bir şey değil:
`rtl/layer_ctrl.sv` yazıldı. `start`'ı üreten o; `active_cols` tile'ın ilk (henüz kabul
edilmemiş) `m_tile_start` beat'inden örnekleniyor, `eng_start` ancak `start_ready` ile
kabul ediliyor ve activation gate CLEAR cycle'ı geçtikten sonra açılıyor — yani `k=0` beat'i
kaybolmuyor. Satır grubu sınırı kabul edilen beat sayacıyla belirleniyor, `w_k` ile değil.
Sözleşme `layer_ctrl`'ün port listesi ve sekiz bitlik `error_flags` ataması olarak yazılı.

### İlk entegrasyon STA'sı: −33,3 ns ile başladı, +1,2 ns ile kapandı

`vivado/check_synth_conv1.tcl` (yeni, conv1 entegrasyon kapısı) 2026-10-07'de ilk kez
`conv1_top`'u sentezledi ve **WNS −33,324 ns** verdi: 3935 failing endpoint, TNS
−112.987 ns, kritik yol `u_window/k_count_reg[0]` → PE accumulator, **67 logic level,
38 CARRY4, 42,790 ns**. Karşılaştırma: compute core tek başına +3,074 ns, `requant_array`
+3,380 ns — ihlalin tamamı daha önce hiç sentezlenmemiş window yolundaydı.

Üç sebep vardı:

1. `window_gen` `ci`/`kh`/`kw` indekslerini `k_count`'tan **kombinasyonel 32-bit bölme ve
   modulo** ile üretiyordu (K_H=K_W=5, yani gerçek divider). 38 CARRY4'ün kaynağı buydu ve
   gereksizdi: `k_count` ardışık arttığı için üç iç içe sayaç aynı eşlemeyi bir adder ve bir
   karşılaştırmayla veriyor. Aynı kalıp `line_buffer`'ın write tarafında da vardı
   (`frame_byte_count / ROW_BYTES`, ROW_BYTES=96, ikinin kuvveti değil).
2. `line_buffer` **kombinasyonel okunuyordu**, yani bellek okuması dividerlarla aynı
   kombinasyonel koninin içindeydi ve `ram_style = "block"` hiçbir zaman uygulanamıyordu.
3. Değerler `integer` (32 bit) temporaries içinde taşınıyordu; gerçek aralıklar 6-13 bit.

Düzeltme iki turda yapıldı ve her tur ölçüldü:

| Adım | WNS | `conv1_top` LUT / FF |
|---|---:|---:|
| Bulunduğu hâl | −33,324 ns | 10947 / 7476 |
| Bölme/modulo → sayaç, senkron okuma, doğru genişlikler | +0,075 ns | 6681 / 7825 |
| Ring'i banka başına ayrı tek boyutlu diziye taşı | **+1,203 ns** | **5013 / 4033** |

İkinci adım şart oldu çünkü +0,075 ns pay bir kapıyı geçer ama implementation'ı geçmez;
o turun kritik yolu `out_base_row` → `line_buffer/rd_byte` idi, 9,918 ns'nin **7,38 ns'si
routing**, logic yalnız 2,538 ns. Sebep belliydi: ring hâlâ iki boyutlu dizi olduğu için
RAM değil flip-flop + mux koni olarak kuruluyordu. Banka başına ayrı diziye alınınca
`line_buffer` 3951 LUT + 3985 FF → **314 LUT + 169 FF + 96 LUTRAM**, `window_gen` 6148 →
**347 LUT**. `ram_style` bilinçli olarak `distributed`: ring K_H satır, yani conv1'de 480
byte, padded conv2 girişinde 560 byte — banka başına 60-70 entry. RAMB18 18 Kb tutar;
block RAM burada yanlış alet, ağırlık bankalarında (banka başına 8192 entry) doğru alet.

Kritik yol artık window yolunda değil: `u_ctrl/cfg_k_reg` → `u_weights/beats_accepted/CE`,
8,544 ns, 10 logic level, route %61,9. Yani sıradaki limiter `layer_ctrl` → `weight_feeder`
komut yolu.

**Bedeli, saklanmadan:** senkron okuma gather'ı aktivasyon beat'i başına dokuz cycle'dan
on cycle'a çıkardı. `tb_conv1_top` ölçümü 76.944 → **85.232 engine cycle** (+%10,8), yani
conv1 frame'i 100 MHz'de **852 µs**. Bu, çalışma kitabının B34'teki 756 µs alt sınırını
ölçümle doğruluyor ve asıl darboğazın array değil generator olduğunu gösteriyor: 8400
beat × 10 cycle, array ise cycle başına bir beat yutabiliyor. Hızlandırma yolu gather'ı
sekiz bankadan paralel okumak (ring zaten sekiz banka), Aşama 2'ye bırakıldı.

**Post-route kanıt (2026-10-07):** `vivado/check_impl_conv1.tcl` (opt/place/phys_opt/route)
**PASS** — setup **WNS +0,920 ns**, hold **WHS +0,050 ns**, 80 DSP48, 16 RAMB36,
4918 LUT / 4033 FF, DRC temiz. Yani bu bir sentez tahmini değil, route edilmiş netlist:
`conv1_top` 100 MHz'i kapatıyor. Hold payı (+0,050 ns) ince; block design'a girildiğinde
gerçek clock ağacıyla yeniden ölçülmeli, OOC run'ın clock'u idealdir.

### Tile sayısı tutarsızlığı kapandı: 112, 98 değil

Yukarıdaki ölçüm tablosu conv1'i 98 tile olarak sayıyor; `tb_conv1_top` 2026-10-07'de
`tile_count = 112` ölçtü ve ikisi de doğru, farklı şeyi sayıyorlar. 98 = `ceil(784/8)`,
yani output pozisyonlarının satır sınırını aşarak paketlendiği ideal. Gerçek `window_gen`
**satır sınırlı**: her output satırı kendi içinde `8/8/8/4` olarak bölünüyor, `28 × 4 = 112`.
Aynı sebeple conv2 26 değil `10 × 2 × 2 = 40`. Fark, her satırın son tile'ının partial
olmasıdır — `active_cols = 4` ile çalışan tile boş MAC slotu harcar. Bu, ADR-002'nin tile
tablosuna not olarak yazıldı; paketlenmiş sayıya ulaşmak pencerenin satır geometrisini
bozmak demek olduğu için schedule değiştirilmiyor.

`conv1_top` (window_gen + layer_ctrl + weight_feeder + compute_engine + requant_array)
2026-10-07'de XSim'de uçtan uca **bit-exact** doğrulandı: `T_CONV1_E2E_001`, 112 tile,
784 output beat ve 784 INT32 accumulator beat, iki farklı backpressure deseniyle iki kez.
Bu top **output buffer içermiyor** — yukarıdaki fiziksel layout kararı yeni kilitlendiği
için address generator henüz yazılmadı; requant stream'i doğrudan dışarı çıkıyor.

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
