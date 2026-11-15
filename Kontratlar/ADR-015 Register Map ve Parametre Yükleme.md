---
title: ADR-015 Register Map ve Parametre Yükleme
created: 2026-09-25
modified: 2026-11-15
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, rtl, axi-lite, register-map]
---

# ADR-015: Register Map ve Parametre Yükleme Protokolü

## Durum
**Kabul edildi — 2026-11-15 (Emin).** Öneri 2026-09-25; map v5'e kadar uygulanmış durumda (aşağıdaki ekler).

Roadmap §6.5 register'ların *hangileri* olduğunu örnek olarak listeliyordu; offset, bit alanı,
reset değeri ve yükleme protokolü tanımsızdı. `(M0, n, bias_q)` register dosyasının tile başına
yeniden yükleneceği [[ADR-003 INT8 Fixed-Point Formatı|ADR-003]]'te yazılı ama *nasıl*
yükleneceği değil. Bu ADR Roadmap §6.5'i örnek olmaktan çıkarıp bağlayıcı hâle getiriyor.

| Madde | Durum |
|---|---|
| `ERR_CFG_M0` zorunlu — yapılandırılmamış cihazı yakalayan tek guard | **Türetilmiş** — ADR-003'ün `n=0` yasallaşmasının doğrudan sonucu |
| Shadow + açık `COMMIT` protokolü | Kabul edildi |
| Offset ve bit alanı düzeni | Kabul edildi (konvansiyon) |
| `PARAM_SRC` mux'ının şimdi konması | Kabul edildi |
| `BUSY` iken commit reddi (erteleme değil) | Kabul edildi |

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

## Ek madde — 2026-09-26: implementasyon sırasında kapatılan beş boşluk

`rtl/axi_lite_regs.sv` yazılıp `T_REG_PARAM_001` XSim'de geçerken (5/5) beş madde tanımsız
çıktı. Offsetler ve shadow/commit protokolü olduğu gibi uygulandı; aşağıdakiler eklendi.

### 1. `LAYER_CFG` alan yerleşimi — tanımsızdı, kilitlendi

Bu ADR `LAYER_CFG`'yi "c_in, kH, kW, stride, pad, out_H, out_W" diye **isimlendiriyordu ama
bit konumu vermiyordu**, bu yüzden implementasyon onu ham 32-bit RW olarak bıraktı. Layer
sequencer bunu decode edecek, PS sürücüsü paketleyecek — tanımsız kalırsa iki taraf farklı
yerleştirir ve arıza "ağ çalışıyor ama çıktı saçma" olarak görünür.

```
0x010 LAYER_CFG  RW
  [ 8: 0] c_in     9 bit, max 511   (conv1=3, conv2=6, FC1=400)
  [11: 9] kH       3 bit, max 7     (5×5 → 5)
  [14:12] kW       3 bit, max 7
  [16:15] stride   2 bit            (1 veya 2)
  [18:17] pad      2 bit            (Aşama 1'de 0 — valid convolution)
  [24:19] out_H    6 bit, max 63    (28/14/10/5/1)
  [30:25] out_W    6 bit, max 63
  [31]    RSVD     RAZ/WI
```

`c_in` 9 bit olmak zorunda çünkü FC1 `1×1` conv olarak `c_in = 400` ile ifade ediliyor
(`K = c_in·kH·kW`). Toplam 31 bit, bir bit yedek.

**Büyüme sınırı:** `out_H`/`out_W` 6 bit, yani 63. Aşama 3'te 64×64 girdi + `5×5` valid
convolution `out = 60` verir, sınıra sığar. Daha büyüğü gerekirse `0x018` (şu an boş)
`LAYER_CFG1` olur — offset tablosunda 0x014'ten 0x040'a boşluk bilerek duruyor.

> RTL'de kalan tek iş bit 31'i RAZ/WI maskelemek; alanlar zaten saklanıyor. Decode WP8
> (layer sequencer) ile gelecek.

### 2. `STATUS[4] = TABLE_VALID` eklendi

Bu ADR'nin `STATUS` tanımı [0:3] bitlerini kullanıyordu. `PARAM_SRC = 1` (BRAM'den tablo)
yolunun kendi başlangıç guard'ı olması gerektiği için bit 4 tanımlandı:

```
0x008 STATUS  RO  [0] IDLE [1] BUSY [2] DONE (W1C) [3] ERROR
                  [4] TABLE_VALID        ← yeni
```

`START` reddi artık `PARAM_SRC`'ye göre doğru kaynağı sorguluyor:
`PARAM_SRC ? !TABLE_VALID : !COMMITTED` → `ERR_PARAM_INCOMPLETE`.

**Neden gerekli:** `COMMITTED` yalnız *register* yolunun yüklendiğini kanıtlar, tablo yolu
hakkında hiçbir şey söylemez. Tablo seçili ve tablo yokken `START` kabul edilirse cihaz sıfır
parametre setiyle çalışır — aritmetik olarak geçerli, her aktivasyon için sessizce `y = 0`.
Bu, `ERR_CFG_M0`'ın kapattığı hata şeklinin **ikinci örneği**; register map hâlâ tanımlanırken
kapatıldı. Reset **güvenli** kaynağı seçer: `PARAM_SRC = 0`.

### 3. W1C yarış kuralı: donanım kazanır

Bir `W1C` biti aynı cycle'da donanım tarafından set edilip yazılım tarafından temizlenirse:
**yazılımın temizlemesi uygulanır, sonra donanım olayı geri OR'lanır** — olay kaybolmaz. Ters
sıralama bir hata bayrağını sessizce yutardı; bu register dosyasının varlık sebebi hataları
görünür kılmak olduğu için kabul edilemez.

### 4. `VERSION` değerleri ve `SOFT_RESET` yan etkisi

`VERSION = { rtl_ver 16'h0001, regmap_ver 16'h0001 }`. Map her değiştiğinde `regmap_ver`
artacak — PS sürücüsü uyuşmazlığı böyle yakalar.

`CONTROL.SOFT_RESET` bir `counter_clear` darbesi üretir; `CYCLE_COUNT`, `STALL_IN`,
`STALL_OUT`, `FRAME_COUNT` bu darbede sıfırlanır. Sayaçlar datapath'e ait olduğu için temizleme
register dosyasında değil orada yaşıyor.

### 5. `n ∈ [1,49]` bilinçli olarak zorlanmadı

Bu ADR o kontrolü "opsiyonel kanarya" diye işaretliyordu ve
[[ADR-003 INT8 Fixed-Point Formatı|ADR-003]] `n = 0`'ı yasallaştırdı — zorlamak ADR-003 ile
çelişirdi. `ERR_CFG_SHIFT` biti map'te duruyor ama set edilmiyor; export-bug kanaryası olarak
ileride bağlanabilir. **Yapılandırılmamış cihaz guard'ı `ERR_CFG_M0`'dır**, bu ADR'nin zaten
söylediği gibi.

## Ek madde — 2026-11-06: register map v3 (`faz4-datapath`)

Kaynak: `faz4-datapath` @ `7fbf3f8`, `rtl/axi_lite_regs.sv` başlık yorumu (alan tablosunun
otoritesi orası). v2 (2026-11-04, `faz3-param`) ve v3 farkları birlikte:

| Adres | Register | v3 alanları | Not |
|---|---|---|---|
| 0x000 | VERSION | [15:0] = `0x0003` | v1 → v2 → v3 |
| 0x004 | CONTROL | [0] START, [1] SOFT_RESET, [2] IRQ_EN, **[3] LAYER_SWAP** (W1P) | LAYER_SWAP busy iken yok sayılır, ERROR[3] |
| 0x014 | TILE_CFG | + **[21:18] LAST_ROWS** (0 = 8) | v2 |
| 0x018 | **LAYER_CFG2** | [8:0] C_PHYS | v2 |
| 0x01C | **W_BASE** | [15:0] ağırlık bank başlangıç adresi | v2; adres = `w_base + tile_idx·k_len + k` |
| 0x020 | **DP_CFG** | [0] SRC_SEL (0 = s_*, 1 = act_buffer), [1] POOL_EN, [2] DST_SEL (0 = act_buffer, 1 = m_*) | v3 |

**Shadow → active her şey için (v3, K3 düzeltmesi).** LAYER_CFG, TILE_CFG, LAYER_CFG2, W_BASE
ve DP_CFG yazımları shadow'a gider; okuma shadow'u döndürür; datapath yalnız active görür;
başarılı COMMIT shadow'u active'e kopyalar ve `k_len`'i commit edilen değerlerden hesaplar.
Bu ADR'nin başta parametre bankları için koyduğu shadow+commit kuralı böylece geometriye de
uzanıyor. Sebep: 2026-11-05 sağlık testinde frame ortasında W_BASE yazmak 784 beat'in 676'sını
sessizce bozdu; "busy iken sonraki tile'ı hazırla" akışı ancak bu ayrımla güvenli.

**COMMIT/START doğrulaması `window_gen` ile eşitlendi:** `out_h = 0`, `out_w = 0`, `pad ≥ kh`,
`pad ≥ kw`, `stride ≠ 1` START'ı reddeder (ERROR[7]).

**ERROR bitleri — yeni kaynaklar mevcut bitleri paylaşıyor** (`LANE-RAPOR-C.md`): [5] okuma
akışında pass sonunda artık word kaldı; [6] act_buffer `seq_error`, window_gen `restart_error`;
[7] act_buffer `ovf_error`, pool `cfg_error`, geometri reddi; [2] requant taşması; [3] busy iken
komut. Datapath hatası pass'i bitirmez: BUSY yüksek kalır, çıkış SOFT_RESET. Kaynakların
ayrılması ve hata durumunda pass'i DONE+ERROR ile bitirmek açık madde.

**SOFT_RESET artık datapath'e ulaşıyor:** conv1_top ve pool2x2 kayıtlı bir datapath reset'iyle,
act_buffer kendi `soft_reset` portuyla (bellek ve bank seçimi korunur). AXI kayıtları korunur.

**PS'nin garanti etmesi gerekenler:** act_buffer kaynaklı katmanda `c_phys = 8 × önceki katmanın
tile sayısı` ve `in_h, in_w` saklanan düzleme eşit (kısa akış hata vermeden kilitler);
s_* kaynaklı katmanda frame her tile pass'inde yeniden gönderilir; `tile_count·h·w ≤ 4608`;
ağırlıklar pass yokken yüklenir.

## Ek madde — 2026-11-07: register map v4, hata sonrası kurtarma

Kaynak: `faz4-datapath` @ `288f84b` (`LANE-RAPOR-L2.md`, `LANE-RAPOR-L3.md`). v3'e göre farklar:

| Adres | Register | v4 | Not |
|---|---|---|---|
| 0x000 | VERSION | [15:0] = `0x0004` | |
| 0x008 | STATUS | + **[5] ABORTED** | pass hatayla bittiğinde; DONE W1C ya da kabul edilen START temizler, SOFT_RESET temizlemez |
| 0x024 | **ERR_DETAIL** | [15:0] sticky, W1C, SOFT_RESET temizler | ERROR bitlerinin kaynağını ayırır |

ERR_DETAIL bitleri: [7:0] conv1_top `error_flags` (ham; [7] geometri / k_len uyumsuzluğu),
[8] act_buffer seq, [9] act_buffer ovf, [10] pool cfg, [11] window restart, [12] kaynak
geometrisi uyuşmazlığı (START reddi), [13] TLAST erken, [14] TLAST geç / pass sonunda artık
word, [15] watchdog.

**Hata artık pass'i bitiriyor (abort).** Pass sırasında datapath hatası (yukarıdaki kaynaklar;
requant taşması ve lockstep hariç, onlar ERROR[2] bayrağı) bir cycle sonra: BUSY düşer, DONE +
ilgili ERROR + ERR_DETAIL + STATUS.ABORTED kurulur, datapath iç reset alır. AXI kayıtları,
act_buffer belleği, saklanan geometri ve tamamlanmış tile maskesi korunur. PS, W1C sonrası
**SOFT_RESET'siz** COMMIT+START ile devam eder; yalnızca yarıda kalan tile yeniden koşulur.

**ERROR bit anlamları ADR'nin ilk tablosuna döndü:** [4] TLAST_EARLY (s_* frame beklenen beat
sayısından önce bitti → abort), [5] TLAST_LATE (son beklenen beat'te s_last yok → yalnız bayrak;
fazla beat kabul edilmez), [6] TIMEOUT (ilerleme watchdog'u, varsayılan 2^24 cycle ≈ 168 ms;
herhangi bir handshake sıfırlar; m_ready tıkalıyken sayaç ancak boru dolduktan sonra ilerler),
[7] konfigürasyon / sıra sınıfı (geometri reddi, act_buffer seq/ovf, pool cfg, restart).

**START kararı registered:** START'tan 4 cycle sonra verilir (aynı CONTROL yazımında
LAYER_SWAP + START = 0x9 desteklenir). Reddedilen durumlar: kaynak act_buffer ise saklanan
geometri commit edilenle eşleşmiyor (`in_h=h, in_w=w, c_phys=8·tiles` ya da FC için
`1×1, c_phys=8·tiles·h·w`) → ERROR[7]+detail[12]; `in_h·in_w·c_phys` 8'in katı değil → ERROR[7].

**act_buffer swap kuralı:** LAYER_SWAP yalnız katmanın 0..tiles−1 tile'larının hepsi yazılmışsa
kabul edilir; aynı katmanda farklı geometrili pass reddedilir (seq_error).

**PS sözleşmesi ekleri:** TLAST_LATE ya da `dst_sel=1` iken abort sonrası ilgili DMA kanalı
sıfırlanır/boşaltılır. FC katmanında `c_in ≤ c_phys = 8·önceki tile sayısı`; fazla lane'ler
ağırlıklarda dışarıda bırakılır (ör. LeNet fc3: c_in 84, c_phys 88).

## Ek madde — 2026-11-15: register map v5, ağırlık yükleme ve interrupt

Kaynak: `faz6-shell` @ `bd844c1`, `rtl/axi_lite_regs.sv` başlık yorumu ve `model/regmap.json`
(v5'ten itibaren alan tablosunun tek kaynağı; SV paketi, Python ve C başlıkları ondan üretilir,
`model/gen_regmap.py --check`). Karar: [[ADR-012 Çalışma Zamanında Ağırlık Yükleme|ADR-012]],
Emin onayı 2026-11-15. **v4'ün hiçbir alanı değişmedi**; v5 yalnız ekler:

| Adres | Register | v5 | Not |
|---|---|---|---|
| 0x000 | VERSION | [15:0] = `0x0005` | |
| 0x028 | **W_ADDR** | RW, [12:0] ADDR, [18:16] BANK, reset 0 | shadow **değil**, doğrudan |
| 0x02C | **W_DATA** | WO, [7:0] DATA; okuma 0 döner | yazma darbesi + ADDR otomatik artar |

**Ağırlık yazma protokolü.** `W_DATA` yazımı tek cycle'lık bir yazma darbesi üretir:
`bank_mem[BANK][ADDR] = DATA`, ardından `ADDR <= ADDR + 1` (13 bit sarar, BANK değişmez). Bir
banka: bir `W_ADDR` yazması + ardışık `W_DATA` yazmaları. `0x01C W_BASE` (v2) ile karıştırılmamalı:
`W_BASE` pass'in okuma taban adresidir ve shadow/commit'e tabidir; `W_ADDR` yükleme imlecidir ve
commit beklemez.

**`BUSY` iken `W_DATA`:** yazma yapılmaz, ADDR artmaz, `ERROR[3]` (`ERR_CFG_WR_BUSY`) kalkar. v3
ekindeki "ağırlıklar pass yokken yüklenir" PS yükümlülüğü böylece donanımda da zorlanıyor.

**Neden shadow değil:** shadow+commit bir pass'in *konfigürasyonunu* atomik yapmak için var.
Ağırlık bellek içeriğidir, on binlerce bayttır ve zaten `BUSY` dışında yazılabilir; shadow'lamak
belleği ikiye katlar ve bir şey kazandırmaz.

**Interrupt.** Yeni çıkış portu `irq = CONTROL.IRQ_EN && STATUS.DONE` (seviye duyarlı; `DONE`'ın
W1C'siyle ya da `IRQ_EN = 0` ile düşer). `CONTROL[2] IRQ_EN` bu ADR'nin ilk tablosunda vardı ama
bir çıkışa bağlı değildi. Abort ile biten pass de `DONE` kurduğu için interrupt üretir; PS
`STATUS.ABORTED` ve `ERROR`'a bakarak ayırır. Blok tasarımda `IRQ_F2P[2]`'ye bağlı (`[0]` DMA
MM2S, `[1]` DMA S2MM).

**Port düzeyi.** `accel_top`'un çıplak `w_wr_*` giriş portları duruyor ve register kaynaklı
yazmayla mux'lanıyor (`w_wr_en` yüksekse dış port kazanır); AXIS kabukta (`accel_axis`) 0'a
bağlılar. Adres penceresi blok tasarımda `0x43C0_0000`, 64 KiB.

**PS sözleşmesi ekleri:** sürücü `VERSION[15:0] == 0x0005` kontrol eder; ağırlık yüklemesinden
sonra `ERROR[3]`'e bakar; `W_DATA` geri okunamaz (yüklenen ağırlığın PS'ten doğrulaması yok).

Doğrulama: `tb_axi_lite_regs` (VERSION), `tb_axis_shell` (yükleme, `BUSY` iken ret, irq),
`tb_prog_e2e` ve Kademe 3 (tam ağ yalnız bu register'larla yüklenip koşuyor).
