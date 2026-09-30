---
title: ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi
created: 2026-09-25
modified: 2026-09-25
type: decision
status: önerildi
tags: [dnn-accelerator, adr, kontrat, axi, rtl, ml]
---

# ADR-016: Aktivasyon Tensör Düzeni ve Byte Yerleşimi

## Durum
**Önerildi — Kişi B onayı bekliyor (2026-09-25).**

[[ADR-006 AXI Stream Paket Semantiği|ADR-006]] veri yolu genişliğini ve frame semantiğini
kilitledi ama **CHW/HWC sırası, 64-bit kelime içindeki byte yerleşimi ve çıkış payload'ı**
tanımsız kaldı. [[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]'in "dönüşümsüz native sıra"
kararı yalnız *ağırlıklar* için geçerli. Bu ADR aktivasyon tarafını kapatıyor.

| Madde | Durum |
|---|---|
| Byte lane haritası (little-endian, dönüşümsüz) | **Türetilmiş** — AXI + Zynq PS endianness |
| `$readmemh` MSB-first tuzağı | **Türetilmiş** — Verilog LRM |
| Beat hizalama tablosu ve FC2 bulgusu | **Türetilmiş** — ADR-002 geometry'sinden aritmetik |
| **HWC** sırası | Onay bekliyor |
| Kanal boyutunun 8'in katına sıfır dolgulanması | Onay bekliyor |
| Çıkış payload formatı | Onay bekliyor |
| Çok katmanlı ara aktivasyon düzeni | **Açık** — Aşama 1 kapsamı netleşince |

## Karar

### 1. Sıra: HWC (kanal en hızlı değişen eksen)

[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] ağırlıkta CHW'yi seçti çünkü orada bedava.
Aktivasyonda tam tersi doğru — [[ADR-005 Direct Convolution|ADR-005]]'in line buffer'ı için:

| | HWC | CHW (kanal başına geçiş) |
|---|---:|---:|
| Conv1 tampon (`kH-1 = 4` satır, `c_in = 3`, W=32) | `4 × 32 × 3 = 384 B` | `28×28×8×4 = 25.088 B` kısmi toplam |
| Oran | — | **~65×** |

CHW imkânsız değil (25 KB Zynq-7020'ye sığar) ama 65× pahalı ve üç geçiş gerektirir.
Ayrıca **çıkışta da HWC doğal**: output-stationary array bir çıkış pikselinin 8 kanalını aynı
anda üretiyor, HWC çıkış tamponsuz.

Kişi A'ya maliyeti besleme script'inde `x.permute(0,2,3,1).contiguous()` — tek satır, host
tarafı, ağırlık düzenine dokunmuyor.

**Girdi frame'i:** `32×32×3` HWC, **padding yok**, 3072 byte = tam 384 beat. ADR-002 bu sayıyı
zaten yazmış; bu karar dolgusuz HWC'yi açık hâle getiriyor.

### 2. Byte yerleşimi

```
mantıksal byte i    →  TDATA[8*(i mod 8) +: 8]
frame'in ilk byte'ı →  beat 0'ın TDATA[7:0]
byte'lar INT8 two's complement, zero-point yok → 0x80 = -128
```

AXI native byte sıralaması + Zynq PS endianness + `numpy.tobytes()` → DDR zincirinin tamamıyla
uyumlu. **Hiçbir yerde reorder yok.**

> [!warning] `$readmemh` tuzağı — [[ADR-009 Doğrulama Ortamı|ADR-009]]'un dosya köprüsünü
> doğrudan etkiler
> `$readmemh` 64-bit'lik bir diziye satır başına **bir word** okur ve en soldaki hex hanesi
> **MSB**'dir, yani mantıksal byte 7. Vektör üreten script her 8 byte'lık grubu şöyle yazmalı:
> ```python
> f.write(f"{int.from_bytes(chunk, 'little'):016x}\n")
> ```
> Yanlış yazılırsa simülasyon "çalışır" ama her beat içinde byte'lar ters döner.

### 3. Beat hizalaması — ADR-006'nın TKEEP değişmezi FC2'de kırılıyor

[[ADR-002 CNN Topolojisi ve Dataset|ADR-002]] geometry'sinden her ara tensör:

| Tensör | Byte | Beat | Durum |
|---|---:|---:|---|
| Input `32×32×3` | 3072 | 384 | ✓ |
| Conv1 `28×28×6` | 4704 | 588 | ✓ |
| Pool1 `14×14×6` | 1176 | 147 | ✓ |
| Conv2 `10×10×16` | 1600 | 200 | ✓ |
| Pool2 `5×5×16` | 400 | 50 | ✓ |
| FC1 `120` | 120 | 15 | ✓ |
| **FC2 `84`** | **84** | **10,5** | ✗ **kırık** |
| FC3 INT8 `10` | 10 | 1,25 | ✗ |
| FC3 INT32 bypass | 40 | 5 | ✓ |

ADR-006 *"TKEEP fonksiyonel olarak sabit all-1"* diyor ve bunu frame boyutlarının 8'e tam
bölünmesine dayandırıyor. **FC2'nin 84 byte'ı bu değişmezi bozuyor.**

**Karar: kanal boyutu 8'in katına sıfır dolgulanır.** Çözüm zaten ADR-002'nin kendi tile
tablosunda duruyor — FC2 output tile = 11, yani `11 × 8 = 88` kanal. Dolgu DDR düzenine de
uygulanırsa 88 B = 11 beat, ADR-006 değişmeden ayakta kalır. Maliyet: 4 byte.

Sıfır dolgu kanal boyutunda zararsızdır: sıfır aktivasyon sıfır katkı verir, ağırlıkları da
sıfırdır.

### 4. Çıkış payload'ı

**Aşama 1, tek katman bring-up:** INT8 aktivasyon frame'i, girişle aynı lane konvansiyonu,
son beat'te `TLAST`. Conv1 için `28×28×6 = 4704 B = 588 beat`.

**Tam ağ, sınıflandırma sonucu — 48 byte / 6 beat:**

```
beat 0..4 : 10 × INT32 logit (little-endian, sınıf 0..9)     40 B
beat 5    : STATUS (32b) + RSVD (32b)                          8 B
            STATUS = [7:0] argmax  [8] sat_seen  [9] acc_ovf_seen
                     [15:10] RSVD  [31:16] frame_id
TLAST = beat 5
```

- **Ham INT32 logit, INT8 değil** — son katmanda requant bypass edilir
  ([[ADR-014 Requantizer Port ve Zamanlama Sözleşmesi|ADR-014]] `cfg_bypass`). Gerekçe iki
  yönlü: argmax'ın karar noktasında clamp/eşitlik riski kalmıyor, **ve** 40 B = 5 beat tam
  bölünüyor (INT8 çıkışta 10 B = 1,25 beat, ADR-006 yine kırılırdı). Maliyet 40 byte.
  Roadmap §4.4 zaten *"karşılaştırmalar sadece final sınıf üzerinde yapılmamalıdır"* diyor.
- **`argmax` ve `frame_id` in-band** — PS'in aldığı paketin gönderdiği frame'e ait olduğunu
  doğrulaması için; DMA descriptor sırası karışırsa sessizce yanlış sınıf okunur.
- **Perf sayaçları pakete konmuyor** — [[ADR-015 Register Map ve Parametre Yükleme|ADR-015]]'te
  register olarak var, iki yerde tutmak ayrışma yüzeyi.

### 5. FC1 ağırlık permütasyonu — ADR-011'in eksik yarısı

HWC saklama, Pool2 çıkışını bellekte `[h][w][c]` sırasına koyar; PyTorch `torch.flatten`
NCHW üzerinden `[c][h][w]` üretir. İkisi farklı. Çözüm donanımda değil, Kişi A'nın export
script'inde tek satır:

```python
w_fc1 = w_fc1.reshape(120, 16, 5, 5).permute(0, 2, 3, 1).reshape(120, 400)
```

ADR-011'in "dönüşümsüz export" maddesi conv ağırlıkları için doğru, **FC1 için değil**.
Yazılmazsa Hafta 8'de "ağ çalışıyor ama doğruluk %10" gizemi olarak döner.

## Açık kalan — çok katmanlı ara aktivasyon düzeni

Önerilen: **`[c_tile][H][W][8]`** (tile-major HWC), kanal sayısı 8'in katı değilse son tile
sıfırla dolgulu. Girdi frame'i bunun tek-tile, dolgusuz özel hâli.

Bu ancak şu cevaplanınca kesinleşir: **Aşama 1'in bitiş hâli tek conv katmanı mı, tam ağ mı?**
Roadmap MVP'de ikisi de işaretsiz. Tek katmansa madde tamamen Aşama 2'ye aittir; tam ağsa
katman sıralayıcı yazılmadan önce kilitlenmelidir.

## Alternatifler
- **CHW aktivasyon:** 65× tampon, üç geçiş, çıkışta ek tamponlama. Elendi.
- **Kanal dolgusu yerine fonksiyonel TKEEP:** ADR-006'nın açıkça basit tuttuğu bir mekanizmayı
  4 byte kazanmak için karmaşıklaştırır. Elendi.
- **Yalnız argmax döndürmek:** Roadmap §4.4 ile çelişiyor, hata ayıklama sinyali yok. Elendi.

## Sonuçlar
- `T_AXI_LANE_001`: bilinen desenli frame gönder → RTL'in gördüğü `(h,w,c)` indeksleri golden
  ile birebir; `$readmemh` yolunun aynı byte sırasını verdiği ayrı test.
- ADR-006'nın TKEEP değişmezi **yalnız kanal dolgusu uygulanırsa** korunur; bu iki ADR artık
  birbirine bağlı.
- Kişi A'nın export/besleme script'ine iki satır eklenir: `permute` (aktivasyon) ve FC1
  ağırlık permütasyonu.
