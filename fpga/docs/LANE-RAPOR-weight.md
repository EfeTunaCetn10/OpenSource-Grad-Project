# LANE-RAPOR — lane/weight, 2026-10-08

Worktree: `C:\grad-wt\weight` (branch `lane/weight`). Dosya sahipliği: `rtl/weight_feeder.sv`,
`tb/tb_weight_feeder.sv`, `model/gen_conv1_vectors.py`, yeni `ADR-011-preload-karar-memosu.md`.
Başka dosyaya dokunulmadı (`conv1_top.sv` dahil — sadece okundu, L1'in dosyası).

## Ne yazıldı

- **`ADR-011-preload-karar-memosu.md`** (yeni, repo kökü) — GÖREV 1, (a) `.coe`+BMG vs
  (b) `$readmemh` karşılaştırması, 9 kriter, öneri (b). Doğrulanan her satır bu makinede
  ölçüldü; doğrulanamayan satırlar "doğrulanmadı" işaretli.
- **`rtl/weight_feeder.sv`** — diff: +47/-9 satır (dosya toplamı 310 satır). Eklenen:
  `parameter string INIT_PREFIX = ""` ve `g_bank` generate bloğu içinde
  `if (INIT_PREFIX != "") $readmemh($sformatf("%s%0d.mem", INIT_PREFIX, gb), bank_mem);`
  taşıyan bir `initial` blok. `INIT_PREFIX=""` (her mevcut örnekleme: `tb_weight_feeder`,
  `conv1_top`) bu kodu hiç çalıştırmıyor — ölçüldü (bkz. "Sentez kanıtı"). `wr_*` portuna,
  reset mantığına, FIFO'ya dokunulmadı.
- **`tb/tb_weight_feeder.sv`** — diff: +168 satır. Mevcut `tb_weight_feeder` modülü
  BİREBİR aynı kaldı (sıfır satır değişti). Yeni ikinci modül: `tb_weight_feeder_init`
  — `wr_en`'i tüm simülasyon boyunca `1'b0`'da tutan, `INIT_PREFIX="../vectors/c1_wbank"`
  ile DUT'u örnekleyen, golden karşılaştırmayı DUT'un kullandığı aynı `.mem` dosyalarından
  (ayrı bir `$readmemh` çağrısıyla) okuyan bir kanıt testi. 8 banka × 75 adres,
  byte-byte karşılaştırma.
- **`model/gen_conv1_vectors.py`** — **değiştirilmedi**. `c1_wbank<r>.mem` adlandırması
  (`INIT_PREFIX` + `<r>.mem`) zaten `INIT_PREFIX` formatıyla birebir örtüşüyor, yeni bir
  üretim yolu gerekmedi. (a) seçilirse bu dosyaya `.coe` çıkışı eklenmesi gerekecek — bkz.
  karar memosu madde 6/9.

## Testler — gerçek çıktı

```
python sim/run_tests.py
```
```
  tb_axi_lite_regs        PASS
  tb_compute_engine       PASS
  tb_conv1_top            PASS
  tb_layer_ctrl           PASS
  tb_pe_os                PASS
  tb_requant_array        PASS
  tb_requant_unit_num     PASS
  tb_requant_unit_timing  PASS
  tb_weight_feeder        PASS
  tb_weight_feeder_init   PASS
  tb_window_gen           PASS

11/11 passed
```
`tb_weight_feeder_init` yeni eklenen testtir; diğer 10 test bu oturumdan önce de vardı,
hepsi hâlâ yeşil. `tb_weight_feeder`'ın kendi iç fazları (FULL_RATE, BP_1/2/MANY,
CONSEC_A/B, ERR_ZERO/KMAX/DEPTH) değişmeden PASS.

## Sentez kanıtı

### 1. Resmî entegrasyon kapısı (değişmeden)

```
vivado -mode batch -source vivado/check_synth_conv1.tcl
```
`conv1_top` hâlâ `weight_feeder`'ı `INIT_PREFIX` geçirmeden örnekliyor (L1'in dosyası,
dokunulmadı), yani bu koşu yeni kodu **tetiklemiyor** — asıl amacı "INIT_PREFIX eklemek
mevcut yolu bozdu mu" sorusuna hayır demek, ve öyle:

```
DSP_CHECK: found 80 DSP48 cells; expected 80 (64 PE + 16 requant)
WNS_CHECK: worst slack 1.203 ns; expected >= 0 at 100 MHz
MEM_REPORT: RAMB36 = 16, RAMB18 = 0, LUTRAM = 29, FF = 4033
WEIGHT_PATH_CHECK: weight_feeder instances = 1, block RAM primitives = 16
PASS: conv1_top synthesized, 80 DSP48, weight path present, WNS 1.203 ns
```
`conv1_top` top-level: Total LUT 5013 (Logic LUT 4850, LUTRAM 110+53 SRL), FF 4033,
RAMB36 16, RAMB18 0, DSP 80 (`reports/conv1_utilization_hier.rpt`). Sadece `u_weights`
alt-hiyerarşisi: 144 LUT, 181 FF, **16 RAMB36**, 0 DSP — ADR-011'in 2026-10-07 ölçümüyle
birebir aynı, regresyon yok.

### 2. INIT_PREFIX gerçekten dolu olduğunda (asıl risk testi)

`check_synth_conv1.tcl`'nin ölçemediği şey — INIT_PREFIX boş değilken $readmemh'li array
BRAM yerine distributed RAM/register'a kaçar mı — için bu makinede, bu oturumda, repo
dışında (scratchpad) tek-seferlik bir `wf_init_wrapper` modülü yazıp `weight_feeder`'ı
`INIT_PREFIX="C:/grad-wt/weight/systolic-array-8x8/sim/vectors/c1_wbank"` ile tek başına
out-of-context sentezledim (`xc7z020clg400-1`, aynı `constraints.xdc`):

```
PROBE_MEM_REPORT: RAMB36 = 16, RAMB18 = 0, LUTRAM = 0, FF = 182
PROBE_WNS_CHECK: worst slack 5.052 ns
PROBE_PASS: INIT_PREFIX path still realized as block RAM (RAMB36=16, RAMB18=0)
```
İzole modül bağlamı farklı olduğu için WNS sayısı `check_synth_conv1.tcl`'ninkiyle
doğrudan kıyaslanamaz (farklı sınır koşulları/pipeline bağlamı), ama negatif slack yok ve
16 RAMB36 aynen korunuyor — yani init kodu gerçekten tetiklendiğinde de BRAM çıkarımı
bozulmuyor. Bu probe repoya commit edilmedi (dosya sahipliğim değil, tek seferlik kanıt).

## Mutasyon testi — 5/5 yakalandı

Her biri `rtl/weight_feeder.sv`'ye enjekte edildi, ilgili testler koşuldu, FAIL doğrulandı,
sonra birebir geri alındı (`git diff` sıfıra döndü, 11/11 tekrar yeşil).

| # | Mutant | Enjekte edilen değişiklik | Yakalayan test | Sonuç |
|---|---|---|---|---|
| 1 | Off-by-one | `INIT_PREFIX` dosya indeksi `gb` → `gb+1` | `tb_weight_feeder_init` | FAIL (447→522 hata, banka kayması); `tb_weight_feeder` etkisiz (wr_* zaten eziyor) |
| 2 | Ters polarite | `if (INIT_PREFIX != "")` → `if (INIT_PREFIX == "")` | `tb_weight_feeder_init` | FAIL (600 hata, `got=xx` — init hiç çalışmadı); `tb_weight_feeder` etkisiz |
| 3 | Yanlış bit alanı | `rd_data[gb*DATA_WIDTH+:...]` → `rd_data[((gb+1)%ROWS)*DATA_WIDTH+:...]` | `tb_weight_feeder` VE `tb_weight_feeder_init` | FAIL (lane rotasyonu, her iki test de düşer) |
| 4 | Kaçırılmış backpressure | `fifo_pop = weight_valid && weight_ready` → `fifo_pop = weight_valid` | `tb_weight_feeder` | FAIL (`weight_data changed while stalled` SVA + 93 scoreboard hatası); `tb_weight_feeder_init` etkisiz (full-rate çalışıyor) |
| 5 | Yanlış reset değeri | reset bloğunda `active <= 1'b0` → `active <= 1'b1` | `tb_weight_feeder` VE `tb_weight_feeder_init` | FAIL (watchdog timeout — `ready` hiç yükselmiyor) |

5/5 yakalandı, yakalanmayan mutant yok.

## Açık kalanlar ve emin olmadıklarım

- **Karar henüz verilmedi.** Memo (b)'yi öneriyor ama seçim Emin'in; (a) seçilirse
  `model/gen_conv1_vectors.py`'ye `.coe` çıkışı, BMG IP kurulumu, ve `run_tests.py`'ye
  IP-kaynak desteği eklenmesi gerekiyor — hiçbiri bugün yok.
- **(b) seçilse bile entegrasyon benim elimde değil.** `conv1_top.sv`'nin `INIT_PREFIX`'i
  gerçek bir yola bağlaması L1'in işi (dosya sahipliğim değil); bugün teslim ettiğim şey
  standalone `weight_feeder` seviyesinde çalışan ve kanıtlanmış bir özellik, entegre
  edilmiş bir uç-uca yol değil.
- **Vivado-tarafı "sentezden önce .mem üret" adımı hiçbir seçenekte yok.**
  `sim/run_tests.py`'nin `ensure_vectors()`'ı sadece simülasyon akışını kapsıyor;
  `vivado/create_project.tcl` veya eşdeğer bir batch akışı `INIT_PREFIX` gerçek bir yola
  bağlanırsa senteze girmeden önce `python model/gen_conv1_vectors.py`'yi çağırmıyor. Bu,
  karar memosunun madde 6/9'unda da işaretlendi, burada tekrar: gerçek açık iş, atlanmadı.
  Bu dosya benim sahipliğimde değil (`vivado/`), orkestratöre/L1'e kalan bir adım.
  `vivado/check_synth_conv1.tcl`'nin kendisi bu sorunu YAŞAMIYOR, çünkü `INIT_PREFIX=""`
  kaldığı sürece hiçbir `.mem` dosyasına ihtiyaç duymuyor.
  `INIT_PREFIX` dolu bir conv1_top konfigürasyonu BUGÜN senteze hiç sokulmadı (yalnızca
  standalone `weight_feeder` seviyesinde) — entegre top'ta WNS farkı olup olmayacağı
  **doğrulanmadı**.
- **(a) tarafının hiçbir satırı ölçülmedi.** BMG IP bu makinede hiç kurulmadı; karar
  memosundaki (a) satırları ADR-011 metnine ve genel Vivado/BMG davranışına dayanıyor,
  "doğrulanmadı" olarak işaretli. Emin (a)'yı tercih ederse bu memo yeniden, gerçek bir
  IP kurulumuyla doğrulanmalı.
- **`$readmemh`'in INIT bitstream özniteliklerinin BMG'ninkiyle bit-bit aynı olduğu**
  iddiası (karar memosu madde 7) genel Xilinx bilgisine dayanıyor; iki netlist'in
  `INIT_xx` dizgelerini bu oturumda bit bit karşılaştırmadım.
- Standalone `wf_init_wrapper` probu scratchpad'de kaldı, repoya commit edilmedi (benim
  dosyam değil, tek seferlik kanıt amaçlıydı) — istenirse yeniden üretilebilir, komutları
  bu raporda var.

## Git

Branch `lane/weight`, henüz commit edilmedi (bu rapor hazırlanırken). Bu oturumun
sonunda şu üç değişiklik commit edilecek: `rtl/weight_feeder.sv`, `tb/tb_weight_feeder.sv`,
`ADR-011-preload-karar-memosu.md`, `LANE-RAPOR.md`. `main`'e dokunulmadı, merge edilmedi.
