# Durum Raporu — 2026-11-07

**Proje:** PYNQ-Z2 üzerinde INT8 CNN hızlandırıcı (8×8 output-stationary systolic array)
**Dal:** `faz4-datapath` @ `288f84b` (taban `main` @ `ce6c04f`, üstünde 33 commit)
**Hedef:** Kasım sonu — Kişi A'nın dondurduğu `v3_48_deep_pool_refine` modelinin XSim'de uçtan uca koşması (Kademe 1)

---

## 1. Özet

| Alan | Durum |
|---|---|
| Datapath | Tek `accel_top` katman döngüsü. Bütün katmanlar (LeNet-5 ve v3-48) aynı donanımdan, yalnızca AXI-Lite register dizisiyle geçiyor. |
| Doğrulama | Temiz ağaçta 16/16 regression. Sistem smoke'ları S1–S7 PASS: tam LeNet zinciri ve v3 kuyruğu (conv4→fc2), saf Python'a karşı bit-exact. |
| Timing (100 MHz) | Sentez WNS +1,593 ns. Route sonrası WNS +0,344 / WHS +0,097 ns (OOC; marj yerleşime duyarlı). |
| Kaynak (accel_top) | 7.677 LUT, 6.499 FF, 48 RAMB36, 88 DSP — xc7z020'nin yaklaşık %14 / %6 / %34 / %40'ı |
| Tam v3 ağı | Parça parça bit-exact; 48×48 → 7 katman → argmax tek parça olarak henüz koşmadı |
| Accuracy | RTL'de ölçülmedi; Kişi A'nın artefaktları bekleniyor |
| Bitstream | Yok. DMA, PS7 block design ve IP packaging kurulmadı. |

---

## 2. Yapılanlar

### 2.1 Kişi A modeli ve parametrik tasarım kararı (4 Kasım)

- **Model:** Kişi A 28 Ekim'de `v3_48_deep_pool_refine` modelini dondurdu: 3×48×48 → 5 conv (3×3, pad 1, 16/24/32/32/32) → 4 pool → FC 288→64→10. INT8 accuracy %70,01 (validation, seed123).
- **Donanıma uyum:** en büyük K 288, bank başına en büyük ihtiyaç 2.304 bayt. `K_MAX` (1024) ve `W_DEPTH` (8192) genişletmesi gerekmedi. Tüm ağırlıklar (bank başına 6.086 B) aynı anda sığıyor.
- **Karar:** derleme zamanı geometrisi yerine runtime `cfg_*` ve `*_MAX` envelope'u (giriş 48×48, kanal 511, satır 512 bayt, kernel 5, pad 2).

### 2.2 `faz3-param` — runtime geometri

- `window_gen`, `line_buffer`, `conv1_top`, `pool2x2` ve `accel_top` geometriyi register'dan alıyor; pad=1 desteği eklendi; Kişi A'nın iki `window_gen` düzeltmesi port edildi.
- Register map v2: `0x018` C_PHYS, `0x01C` W_BASE, `TILE_CFG[21:18]` LAST_ROWS.
- `weight_feeder`'a `base` girişi eklendi; başlangıç adresi iki register aşamasında önceden hesaplanıyor. Bu, komut yolundaki −0,826 ns'i +1,470 ns'e çıkardı.

### 2.3 Sağlık testi (5 Kasım)

- Beş lane sekiz boyutu taradı: kontrat izlenebilirliği, tasarım, sim→donanım, fiziksel, envelope, Kişi A uyumu.
- Sonuç: **7 Kırmızı, 17 Sarı, 5 Yeşil.** En kritik bulgular:
  - **K1:** `window_gen` girdiyi HWC okuyordu, depolama ise tile-major'dı; v3 conv2–conv5 yanlış sonuç veriyordu.
  - **K2:** reset başına yalnızca tek frame işlenebiliyordu.
  - **K3:** register'lar çalışırken canlıydı.
  - **K4:** `act_buffer` ping-pong'u bozuktu.
- `accel_top` ilk kez route edildi.

### 2.4 `faz4-datapath` — tam katman datapath'i (6 Kasım)

- **`act_buffer`:** tile-major depoluyor, HWC sırasında okuyor (rd_ready=1'de bubble yok); bankı katman başına `LAYER_SWAP` ile değiştiriyor.
- **Register map v3:** geometri, tile, W_BASE ve DP_CFG için shadow→active (COMMIT'te kopyalanıyor); `DP_CFG @0x020` (src_sel, pool_en, dst_sel); `CONTROL[3]` LAYER_SWAP.
- **`accel_top` akışı:** kaynak mux'u (s_* ya da act_buffer) → conv1_top (her START'ta restart + frame_start) → lane maskesi → pool ya da bypass → act_buffer ya da m_*.
- **FC flatten sırası (h, w, c)** oldu. FC1 ağırlıkları `reshape(64,32,3,3).permute(0,2,3,1)` ile export edilmeli.
- K1–K4 kapandı.

### 2.5 Açıkların kapanması (7 Kasım)

- **Register map v4:** `ERR_DETAIL @0x024` (16 ayrı kaynak biti), `STATUS[5]` ABORTED.
- **Hata = abort:** datapath hatası pass'i DONE + ERROR + ABORTED ile bitiriyor. act_buffer belleği ve tamamlanmış tile maskesi korunuyor; SOFT_RESET gerekmeden devam ediliyor.
- **Yeni kontroller:**
  - START'ta kaynak geometrisi kontrolü (FC flatten dahil);
  - s_* frame'i için TLAST erken (abort) / geç (bayrak);
  - ilerleme watchdog'u (varsayılan 2^24 cycle ≈ 168 ms);
  - act_buffer'da swap ancak katmanın bütün tile'ları yazılmışsa kabul ediliyor.
- **Timing:** requant ile pool arasına register slice eklendi.

### 2.6 Kanıt

| Test | Sonuç |
|---|---|
| `python sim/run_tests.py` (temiz ağaç) | 16/16 PASS |
| S1 | conv1 (48×48, pad1, 2 tile, pool) → conv2 (act_buffer'dan HWC, 3 tile) → conv3 (4 tile) → m_*: bit-exact |
| S2, S3 | Tekrarlı START; pass ortasında register yazımı — çıktı bozulmuyor |
| S4, S7a/b/c | Taşma, geometri reddi, kısa frame, watchdog → abort; ardından SOFT_RESET'siz iyi pass |
| S5 | LeNet: conv1 → pool → conv2 → pool → fc1 (400) → fc2 → fc3 → m_*: bit-exact |
| S6 | v3 kuyruğu: conv4 → pool → conv5 → pool → fc1 (288) → fc2 → m_*: bit-exact |
| Mutasyon | Her yeni mekanizmada en az bir mutant testte yakalandı (L3'te 10 mutanttan 9'u; hayatta kalan, `line_buffer`'ın kendi korumasıyla çakışan yedek kapı) |

Smoke'lar bu commit'le `smoke/` altında: `bash smoke/run_smoke.sh <rtl dizini>`.

### 2.7 Belgeler

- ADR-015'e v3 ve v4 ekleri (register haritası, abort semantiği, PS sözleşmesi).
- ADR-018'e ek: HWC okuma ve FC sırası (h, w, c).
- ADR-019 (geometry envelope) — **hâlâ "önerildi"**; envelope tablosu K=1152 varsayımıyla yazılmış, revize edilmedi.

---

## 3. Yapılmayanlar / açık riskler

| # | Konu | Etki | Not |
|---|---|---|---|
| R1 | **Kişi A artefaktları** (checkpoint, qparam, katman vektörleri, 48×48 ön-işleme) | Gerçek modelle bit-exact ve accuracy ölçülemiyor | İstek notu vault'ta taslak, gönderilmedi |
| R2 | **Tam v3 ağı tek parça** (48×48 → 7 katman → argmax) | Kasım hedefinin kendisi | Parçaları bit-exact |
| R3 | **Timing marjı:** `window_gen` handshake'i → PE CE yolu, %77 route | Karttan önce kapanmalı | ±0,4 ns yerleşim oynaması |
| R4 | **Bitstream kulvarı:** AXI DMA, PS7 block design, IP packaging, `s_axis_*` adları, ağırlıklar için AXI yolu, interrupt | Kartta koşmayı engeller | Kademe 3/4 |
| R5 | **Kontrattaki 9 test ID'si yazılmadı** (`T_NUM_OVF_001`, `T_AXI_BP_001`, `T_AXI_LANE_001`, `T_STA_001`, `T_RST_001`, `T_NUM_CONV_001`, `T_ML_ACC_001`, `T_MEM_PINGPONG_001`, `T_CDC_001`) | İzlenebilirlik | Bir kısmı smoke'larla davranışsal olarak kapsanıyor |
| R6 | **Smoke'lar `tb/` regression'ına alınmadı** | Kalıcı koruma yok | Bu commit'le `smoke/` altında saklanıyor |
| R7 | **PYNQ image ↔ Vivado 2025.1 uyumu doğrulanmadı** | Overlay yükleme hatası riski | ADR-001 açık konusu |
| R8 | **ADR-016 ham INT32 logit diyor; doğrusu INT8 logit** (ağırlık ölçeği kanal başına) | Belge hatası | ADR düzeltilecek |
| R9 | **ADR-019 kabul edilmedi, envelope tablosu güncel değil**; Abstract / Roadmap eski akışı anlatıyor | Belge tutarlılığı | |
| R10 | `lockstep_error` abort etmiyor (yalnızca bayrak); SOFT_RESET STATUS.ABORTED'ı temizlemiyor | Küçük | Bilinçli |

---

## 4. Planlananlar (test fazı önerisi)

| Hafta | İş | Bağımlılık |
|---|---|---|
| 9–15 Kasım | Smoke'ların kalıcı teste dönüşmesi (`tb_sys_*`); kontrat test ID eşlemesi; seed'li rastgele geometri testi (`--random N`) | yok |
| 16–22 Kasım | `tb_v3_e2e`: 48×48 → 7 katman → argmax, sentetik ağırlıkla; Kişi A JSON'undan `wbank*.mem` ve param tablosu üreten yükleyici | yok |
| 23–30 Kasım | Gerçek ağırlıkla 8+ görüntüde bit-exact; accuracy, Python INT8 forward'ından tüm sette | **R1** |
| Paralel | `window_gen` handshake'inin register'lanması (R3) | test ağı kurulduktan sonra |
| Aralık | Bitstream kulvarı (R4), Kademe 3 (PS VIP + DMA), Kademe 4 (kart) | |

**Accuracy argümanı:** RTL birkaç görüntüde Kişi A'nın INT8 golden'ıyla bit-exact ise, tüm setteki
accuracy Python'un INT8 accuracy'sine eşittir. Kartta ölçülen accuracy Kademe 4'ün işidir.

**Bekleyen kararlar (Emin):**
1. İstek notunun Kişi A'ya gönderilmesi.
2. Test yazım yolu: lane'ler / Emin yazar / karma (öneri: karma — `tb_v3_e2e` iskeletini Emin yazar).
3. Rastgele geometri testinin ayrı komut olarak koşması.

---

## 5. Dal haritası (ProjectPriv)

| Dal | İçerik |
|---|---|
| `main` @ `ce6c04f` | Dokunulmadı |
| `faz2-sim-e2e` @ `2985e8e` | LeNet-5 Kademe 1 (16/16), 9 Ekim |
| `faz3-param` @ `71663f1` | Runtime geometri, 4 Kasım |
| `faz4-datapath` | Bu rapor; tam katman datapath'i ve açıkların kapanması |

---

## 6. Güncelleme — 2026-11-08 (`faz5-test`)

Dört paralel lane, orkestratör doğrulamasıyla:

| Risk | Sonuç | Kanıt |
|---|---|---|
| **R2 tam v3 ağı** | **Kapandı (sentetik ağırlıkla).** `tb_v3_e2e`: 48×48 → conv1..conv5 → fc1 → fc2 → argmax, testbench PS rolünde yalnız AXI-Lite + akış portlarıyla; 2 görüntü, 54 pass, her katmanın act_buffer içeriği (4.696 word) + logit'ler saf Python'a karşı bit-exact; tahminler 3 ve 8 | regression |
| **R3 timing** | `window_gen` handshake yolu kritik yoldan çıktı (redundant `gather_reg` temizlikleri kaldırıldı, hazırlık kontrolü bir cycle önce register'lanıyor). Route sonrası **WNS +0,899 / WHS +0,016 ns**, Default ve Explore stratejilerinde aynı. Yeni sınırlayıcı: `dp_rst_n` → requant reset fan-out'u (`max_fanout=64` denendi, +0,743'e kötüleştirdi, geri alındı) | orkestratör route koşusu |
| **R5/R6 testler** | Smoke S1–S7 kalıcı regression'a alındı (`tb_sys_chain`, `tb_sys_faults`); yeni testler `tb_sys_bp` (T_AXI_BP_001), `tb_sys_ovf` (T_NUM_OVF_001); PASS satırlarında T_MEM_PINGPONG_001, T_NUM_CONV_001, T_RST_001. Tam eşleme: `TEST-MATRISI.md` | regression |
| **R8/R9 belgeler** | ADR-016/014 INT8 logit düzeltmesi; ADR-019'a gerçek envelope eki (kabul Emin'de); Abstract/Roadmap'e güncel durum notu; ADR-008 senkron reset eki (vault) | — |

**Regression:** temiz ağaçtan **21/21 PASS**; `smoke/run_smoke.sh` SMOKE PASS. Sentez +1,593 ns,
LUT 8.715, FF 6.516, 48 RAMB36, 88 DSP. Toplam mutasyon: P1 1, P2 2, P3 8 — hepsi yakalandı.

**Hâlâ açık:** R1 Kişi A artefaktları (not gönderilmedi) · R4 bitstream (DMA, BD, IP packaging) ·
R7 PYNQ uyumu · `dp_rst_n` fan-out'u (+1,0 ns için reset'i requant veri register'larından
kaldırmak) · ADR-019/014 kabul kararları · T_FC1_ORDER_001 one-hot ve koordinat kodlu
T_AXI_LANE_001 testleri · kontrattaki "accumulator wrap" ifadesinin "acc+bias" olarak düzeltilmesi.
