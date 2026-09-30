---
title: ADR-015 Register Map ve Parametre Yükleme
created: 2026-09-25
modified: 2026-09-25
type: decision
status: önerildi
tags: [dnn-accelerator, adr, kontrat, rtl, axi-lite, register-map]
---

# ADR-015: Register Map ve Parametre Yükleme Protokolü

## Durum
**Önerildi — Kişi B onayı bekliyor (2026-09-25).**

Roadmap §6.5 register'ların *hangileri* olduğunu örnek olarak listeliyordu; offset, bit alanı,
reset değeri ve yükleme protokolü tanımsızdı. `(M0, n, bias_q)` register dosyasının tile başına
yeniden yükleneceği [[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'te yazılı ama *nasıl*
yükleneceği değil. Bu ADR Roadmap §6.5'i örnek olmaktan çıkarıp bağlayıcı hâle getiriyor.

| Madde | Durum |
|---|---|
| `ERR_CFG_M0` zorunlu — yapılandırılmamış cihazı yakalayan tek guard | **Türetilmiş** — ADR-003'ün `n=0` yasallaşmasının doğrudan sonucu |
| Shadow + açık `COMMIT` protokolü | Onay bekliyor |
| Offset ve bit alanı düzeni | Onay bekliyor (konvansiyon) |
| `PARAM_SRC` mux'ının şimdi konması | Onay bekliyor |
| `BUSY` iken commit reddi (erteleme değil) | Onay bekliyor |

## Karar

### Register map

```
0x000 VERSION       RO   [31:16] rtl_ver, [15:0] regmap_ver          reset: sabit
0x004 CONTROL       RW   [0] START (W1S, oto-temizlenir)
                         [1] SOFT_RESET (W1S)  [2] IRQ_EN            reset: 0
0x008 STATUS        RO   [0] IDLE [1] BUSY [2] DONE (W1C) [3] ERROR   reset: IDLE=1
0x00C ERROR         W1C  [0] ERR_CFG_M0        [1] ERR_CFG_SHIFT
                         [2] ERR_ACC_OVF       [3] ERR_CFG_WR_BUSY
                         [4] ERR_TLAST_EARLY   [5] ERR_TLAST_LATE
                         [6] ERR_TIMEOUT       [7] ERR_PARAM_INCOMPLETE   reset: 0
0x010 LAYER_CFG     RW   c_in, kH, kW, stride, pad, out_H, out_W      reset: 0
0x014 TILE_CFG      RW   [7:0] t  [15:8] tile_count
                         [16] REQ_BYPASS  [17] PARAM_SRC              reset: 0

; per-bank parametre bloğu, 16 byte hizalı — i = 0..7, taban = 0x040 + 16*i
  +0x0 BIAS_Q[i]    RW   signed 32-bit                                reset: 0
  +0x4 M0[i]        RW   [17:0] M0,  [31:18] RSVD (RAZ/WI)            reset: 0
  +0x8 SHIFT[i]     RW   [5:0] n, [8] relu, [31:9] RSVD (RAZ/WI)      reset: 0
  +0xC RSVD         RO   0    ; hizalama + ileride zero-point için yer

0x0C0 PARAM_COMMIT  W1S  [0] COMMIT                                   reset: 0
0x0C4 PARAM_STATUS  RO   [23:0] written_mask (word başına 1 bit)
                         [24] COMMITTED                               reset: 0
0x100 CYCLE_COUNT   RO   toplam çalışma çevrimi                       reset: 0
0x104 STALL_IN      RO   input starvation çevrimi                     reset: 0
0x108 STALL_OUT     RO   output backpressure çevrimi                  reset: 0
0x10C FRAME_COUNT   RO   işlenen frame sayısı                         reset: 0
```

### Yükleme protokolü — shadow + commit

1. PS, 8 banka × 3 word = **24 yazma** yapar. Hepsi **shadow** register dosyasına gider,
   her yazma `written_mask`'te kendi bitini set eder. Aktif parametrelere doğrudan yazılamaz.
2. PS `PARAM_COMMIT.COMMIT` yazar. Donanım doğrular:
   - `written_mask == 24'hFFFFFF`
   - her `M0 ∈ [2^16, 2^17)` → **zorunlu**
   - her `n ∈ [1,49]` → opsiyonel kanarya (bkz. aşağıda)
3. **Geçerse:** shadow → active atomik kopya, `COMMITTED = 1`, mask temizlenir.
   **Geçmezse:** ilgili `ERROR` biti set edilir, **kopya yapılmaz**, aktif parametreler
   dokunulmaz.
4. `CONTROL.START`, `COMMITTED == 0` iken reddedilir → `ERR_PARAM_INCOMPLETE`.
5. `BUSY` iken **shadow'a yazmak serbesttir** (tile `t+1` hazırlanabilir), **commit
   reddedilir** → `ERR_CFG_WR_BUSY`. Tile sınırında ertelenmiş commit Aşama 2 yükseltmesidir.

**Neden shadow+commit, "start zaten son yazmadır" değil:** 24 word AXI4-Lite üzerinden atomik
yazılamaz. Yarım yüklenmiş bir parametre setiyle başlamak sessiz yanlış sonuç üretir; commit
ayrıca aralık kontrollerinin doğal yeridir.

### `ERR_CFG_M0` neden zorunlu

[[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'ün 25 Eylül revizyonunda `n` aralığı `[0,63]`
olarak genişledi ve tüm değerler aritmetik olarak tanımlı hâle geldi. Bunun bir yan etkisi
var: eski taslakta `SHIFT` reset değeri `0` illegal olduğu için "yapılandırılmamış cihaz
başlayamaz" garantisi bedavaydı. **Bu garanti kayboldu** — reset sonrası
`M0 = 0, n = 0, bias = 0` ile cihaz sessizce `y = 0` üretir.

`M0 ∈ [2^16, 2^17)` hâlâ bağlayıcı bir ADR-003 maddesi ve `M0 = 0` bunu ihlal ediyor. Guard
bu yüzden `ERR_CFG_M0`'a taşındı; `ERR_CFG_SHIFT` korrektlik için gerekli değildir ve yalnız
export-bug kanaryası olarak tutulur (`n ≥ 33` pratikte `M < 1,1e-5` demektir).

### `PARAM_SRC` — şimdi konmalı, sonra taşınamaz

Parametreler **output-channel tile'ı** başına değişir (output-position tile'ı başına değil).
[[ADR-002 CNN Topolojisi ve Dataset|ADR-002]] geometry'sinden:

| Katman | Param yükleme | Hesap (cycle) |
|---|---:|---:|
| Conv1 | 1 | 7.350 |
| Conv2 | 2 | 3.900 |
| FC1 | 15 | 6.000 |
| FC2 | 11 | 1.320 |
| FC3 | 2 | 168 |
| **Toplam** | **31 yükleme** | **18.738 ≈ 187 µs @100 MHz** |

31 × 25 yazma (24 word + commit) = **775 AXI4-Lite yazma**:

- `0,1 µs/yazma` (bare-metal) → **78 µs**, hesabın %41'i
- `1 µs/yazma` (PYNQ Python MMIO) → **775 µs**, hesabın **4×'i**

Dağılım kritik: conv katmanlarında 3 yükleme / 11.250 cycle, ihmal edilebilir. **Yük tamamen
FC'de: 28 yükleme / 7.488 cycle** — en iyi senaryoda hesapla başabaş, kötüsünde 10 katı.
Bu, [[ADR-007 DMA Modu|ADR-007]]'de belgelenen Huynh AXI-Lite darboğazının küçük kardeşidir.

`TILE_CFG.PARAM_SRC`: `0` = AXI4-Lite register dosyası (bring-up, `T_NUM_REQ_001`, debug),
`1` = **BRAM'den tile indeksiyle otomatik yükleme** (katman başına bir `layerN_requant.coe`,
[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]'in `.coe` akışına birebir oturur; Kişi A'nın
script'i `M0`/`n`'i zaten üretiyor).

Aşama 1'de `PARAM_SRC = 0` ile ilerlenir, **ama mux şimdi konur** — sonradan eklemek register
map'i kırar. Hangi satırda olduğumuzu AXI4-Lite yazma gecikmesinin gerçek ölçümü söyleyecek;
bu ölçüm bir kez yapılmalı.

## Alternatifler
- **Shadow'suz, "yaz ve başlat":** atomiklik garantisi yok, torn update sessiz yanlış sonuç.
  Elendi.
- **Yalnız BRAM'den yükleme (register dosyası yok):** bring-up ve birim testi için
  `T_NUM_REQ_001`'in parametreyi tek tek sürebilmesi gerekiyor. Elendi.
- **Tile sınırında ertelenmiş commit:** Aşama 1'de doğrulama maliyeti kazancından fazla;
  Aşama 2 yükseltmesi olarak park edildi.

## Sonuçlar
- Roadmap §6.5 artık örnek değil, bu tablo bağlayıcı.
- `T_REG_PARAM_001`: eksik word ile commit → red + `ERR_PARAM_INCOMPLETE`; `M0 = 0` ile commit
  → red + `ERR_CFG_M0`, aktif parametre değişmedi (okuyarak doğrula); `BUSY` iken commit → red;
  geçerli commit → 8 bankanın da yeni değerle çalıştığı uçtan uca.
- PS sürücüsü commit dönüşünü kontrol etmeden `START` yazmamalı.
