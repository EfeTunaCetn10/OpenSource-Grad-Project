# faz6 seam kontratı — Kişi B uçtan uca kabuk (2026-11-14)

Taban: `faz5-test` @ `df26688` → entegrasyon dalı `faz6-shell`. Orkestratör: Fable (kod yazmaz;
kontrat, dispatch, doğrulama, git). Kod: Codex lane'leri. Bu dosya bağlayıcıdır; kontrat yanlış ya
da eksikse **uyma, dur ve raporunda itiraz et**.

## 0. Hedef

PS'te duran bir INT8 görüntüden PS'te okunan sınıfa kadar zincirin Kişi B tarafı:

```
model.json ─► netprog (host) ─► program + girdi/çıktı vektörü
                                   │
        ┌──────────────────────────┼───────────────────────────┐
        ▼                          ▼                           ▼
 XSim: tb_prog_e2e          XSim: PS7 VIP + AXI DMA      Kart: PYNQ sürücü
 (accel_axis, Kademe 1/2)   + blok tasarım (Kademe 3)    (Kademe 4)
```

Üç tüketici de **aynı program dosyasını** yürütür. Sürücü mantığı tek kaynaktan gelir (ADR-017).

## 1. Bugünkü durum (ölçülmüş)

- `accel_top`: tek katman datapath'i, regmap v4, 21/21 regression, tam v3 ağı `tb_v3_e2e`'de
  sentetik ağırlıkla bit-exact. Akış portları çıplak (`s_valid/s_ready/s_data/s_last`,
  `m_valid/m_ready/m_y_flat/m_last`), ağırlık yazma çıplak port (`w_wr_*`), interrupt portu yok.
- `m_y_flat` zaten lane maskeli (geçersiz lane = 0) ve `m_last` pass'in son beat'i.
- Blok tasarım, DMA, IP sarmalayıcı, PS sürücüsü, model yükleyici yok.

## 2. Gereksinimler (Kişi B, girdi → çıktı)

| ID | Gereksinim | Lane | Doğrulama |
|---|---|---|---|
| B-01 | Ağırlıklar PS'ten AXI üzerinden yüklenir (çıplak port değil) | S | `tb_axis_shell` |
| B-02 | Akış arayüzleri AXI4-Stream adlı, 64-bit, TKEEP/TLAST'lı (ADR-006) | S | `tb_axis_shell` |
| B-03 | Pass bitişinde interrupt (`IRQ_EN`) | S | `tb_axis_shell` |
| B-04 | Vivado block design'a module reference olarak girebilen düz Verilog sarmalayıcı | S | `check_synth_axis.tcl` |
| B-05 | Register haritası tek kaynaktan SV / Python / C'ye üretilir | M | `gen_regmap.py --check` |
| B-06 | Model JSON → banka görüntüsü, `w_base`, tile başı parametre, pass programı | M | `netprog.py --selftest` |
| B-07 | Program tek başına tam ağı sürer: AXIS kabukta bit-exact logit + argmax | T | `tb_prog_e2e` |
| B-08 | `T_FC1_ORDER_001` one-hot, `T_AXI_LANE_001` koordinat kodlu | T | regression |
| B-09 | PYNQ sürücüsü programı yürütür; host'ta sahte MMIO/DMA ile test edilir | P | `test_driver_mock.py` |
| B-10 | PS7 + AXI DMA (simple, 64-bit) + hızlandırıcı blok tasarımı, Tcl ile yeniden kurulur | B | `build_bd.tcl` |
| B-11 | Kademe 3: PS7 VIP + DMA + DDR üzerinden aynı program, bit-exact | B | `run_k3` |
| B-12 | Tam tasarım route + bitstream + `.hwh`; post-route WNS ≥ 0, `report_cdc` temiz | orkestratör | Vivado raporu |
| B-13 | Accuracy (`T_ML_ACC_001`) | — | **Kişi A artefaktlarına bağlı, bu fazda yok** |

## 3. Register map v5 (v4'e ek; v4'ün hiçbir alanı değişmez)

```
0x000 VERSION   [15:0] = 0x0005
0x028 W_ADDR    RW  [12:0] ADDR, [18:16] BANK      reset 0   (shadow DEĞİL, doğrudan)
0x02C W_DATA    WO  [7:0] DATA; okuma 0 döner
```

- `W_DATA` yazımı: `bank_mem[BANK][ADDR] = DATA` (tek cycle `w_wr_en`), sonra `ADDR <= ADDR + 1`
  (13 bit sarar, BANK değişmez).
- `BUSY` iken `W_DATA` yazımı: yazma yapılmaz, ADDR artmaz, `ERROR[3]` kalkar.
- `irq` (yeni çıkış portu) = `CONTROL.IRQ_EN && STATUS.DONE` (seviye; DONE W1C ile düşer).
- `accel_top`'un mevcut `w_wr_*` giriş portları **kalır** (21 test onları kullanıyor); register
  kaynaklı yazma içeride onlarla OR/mux'lanır. Mevcut hiçbir testbench değiştirilmez.

## 4. AXIS kabuk — `rtl/accel_axis.sv` + `rtl/accel_axis_wrapper.v`

```
aclk, aresetn (aktif düşük, senkron)
s_axi_*      AXI4-Lite, ADDR_W=12, 32-bit  (+ awprot/arprot girişleri, yok sayılır)
s_axis_tdata[63:0] tkeep[7:0] tlast tvalid tready     giriş frame'i (src_sel=0 pass'leri)
m_axis_tdata[63:0] tkeep[7:0] tlast tvalid tready     çıkış (dst_sel=1 pass'leri)
irq
```

- `s_axis_tkeep` yok sayılır (frame her zaman 8 baytın katı; START bunu zaten denetliyor).
- `m_axis_tdata = m_y_flat` (lane r → bit 8r+7:8r), `m_axis_tkeep = 8'hFF`, `m_axis_tlast = m_last`.
- Bir DMA transferi = bir pass. Çok tile'lı `dst_sel=1` katmanında (ör. fc2: 2 tile) her tile ayrı
  bir S2MM transferidir (1 beat + TLAST). `src_sel=0` katmanında frame her tile pass'inde yeniden
  gönderilir (ADR-015 v3 eki).
- `accel_axis_wrapper.v`: düz Verilog-2001, yalnız `accel_axis`'i örnekler; `X_INTERFACE_INFO` /
  `X_INTERFACE_PARAMETER` öznitelikleriyle `S_AXI`, `S_AXIS`, `M_AXIS`, clock (ASSOCIATED_BUSIF,
  ASSOCIATED_RESET), reset ve interrupt arayüzleri çıkarılır. SV unpacked port yok.

## 5. Model JSON (netprog girdisi)

Kişi A'dan istenen biçimin kendisi (2026-11-08 istek notu §2). Float yok.

```json
{ "name": "v3_48_synth",
  "input": {"h": 48, "w": 48, "c": 3},
  "layers": [
    { "name": "conv1", "kind": "conv", "c_in": 3, "c_out": 16, "kh": 3, "kw": 3, "pad": 1,
      "pool": true,
      "weights": [[...K int8...], ... c_out satır],   // k = ci*kh*kw + ky*kw + kx
      "bias_q": [...c_out int32...], "m0": [...], "n": [...], "relu": [0/1 ...] },
    { "name": "fc1", "kind": "fc", "c_in": 288, "c_out": 64, ...
      // fc ağırlık sırası: k = (h*W + w)*C + c  (flatten (h,w,c)); kh=kw=1, pad=0, pool=false
    } ] }
```

Donanım eşlemesi `model/gen_v3_e2e_vectors.py` + `tb/tb_v3_e2e.sv` ile **aynı** olmalı (onlar
otoritedir): banka `r = oc mod 8`, adres `w_base + (oc div 8)*k_len + k`, katmanlar art arda
yerleşir; conv1 `c_phys = c_in` ve s_* kaynaklı; sonraki katmanlar act_buffer kaynaklı,
`c_phys = 8 × önceki katmanın tile sayısı` (fc için `× h × w`); son katman `dst_sel=1`,
`last_rows = c_out mod 8`. Envelope ihlali (K > 1024, banka > 8192 B, `tiles·h·w > 4608`,
`M0 ∉ [2^16, 2^17)`, in > 48×48, kernel > 5, pad > 2) packer'da **hata**dır, sessiz kırpma yok.

## 6. Program biçimi (tek kaynak; TB, Kademe 3 ve sürücü aynısını okur)

Düz metin, satır başına bir işlem, sayılar hex (0x öneki yok), `#` yorum:

```
W <addr> <data>            AXI-Lite yaz
R <addr> <mask> <value>    AXI-Lite oku; (okunan & mask) == value olmalı, değilse HATA
P <addr> <mask> <value>    eşit olana dek yokla (zaman aşımı tüketicide; aşılırsa HATA)
S <offset> <nbeats>        <ad>_in.mem[offset..] içinden nbeats beat'i s_axis'e göndermeyi BAŞLAT
                           (asenkron; son beat TLAST)
M <offset> <nbeats>        m_axis'ten nbeats beat almayı BAŞLAT (asenkron; son beat TLAST olmalı);
                           alınan veri <ad>_exp.mem[offset..] ile karşılaştırılır
J                          bekleyen bütün S/M transferleri bitene dek bekle
```

Dosyalar: `<ad>.prog`, `<ad>_in.mem`, `<ad>_exp.mem` (64-bit hex kelime, `$readmemh` biçimi),
`<ad>_meta.json` (sınıf sayısı, beklenen argmax, logit'lerin `_exp.mem` içindeki yeri ve lane
düzeni). Bir pass'in kalıbı: shadow yazımları → `W COMMIT` → gerekiyorsa `S` ve/veya `M` →
`W CONTROL START` (gerekirse LAYER_SWAP ile aynı yazımda değil, ayrı) → `P STATUS DONE` →
`R STATUS` (ERROR ve ABORTED 0) → `W STATUS DONE` (W1C) → `J`. Program başında VERSION denetimi ve
ağırlık yüklemesi (`W_ADDR`/`W_DATA`), sonunda `R ERROR == 0`, `R ERR_DETAIL == 0`.
Görüntü başına ağırlık yeniden yüklenmez: `<ad>.prog` = kurulum + N görüntü.

## 7. Lane'ler ve dosya sahipliği

Bir lane yalnız kendi dosyalarına yazar. `sim/run_tests.py`, `filelist.f` ve bu kontrat
orkestratöründür; gereken tek satırlık eki raporunda ver.

| Lane | Dalga | Sahip olduğu dosyalar |
|---|---|---|
| **S** kabuk RTL | 1 | `rtl/axi_lite_regs.sv` (yalnız v5 eki), `rtl/accel_top.sv` (yalnız w_wr mux + irq), **yeni** `rtl/accel_axis.sv`, `rtl/accel_axis_wrapper.v`, `tb/tb_axis_shell.sv`, `vivado/check_synth_axis.tcl` |
| **M** model/program | 1 | **yeni** `model/regmap.json`, `model/gen_regmap.py`, `model/netprog.py`, `model/gen_netprog_vectors.py`, üretilen `tb/accel_regs_pkg.sv`, `sw/common/accel_regs.py`, `sw/common/accel_regs.h` |
| **T** program testi | 2 | **yeni** `tb/tb_prog_e2e.sv`, `tb/tb_fc1_order.sv`, `tb/tb_axis_lane.sv` ve gerekirse generator'ları; `model/netprog.py` içerik düzeltmeleri (biçim değişmez) |
| **P** PYNQ sürücü | 2 | **yeni** `sw/pynq/accel_driver.py`, `sw/pynq/run_network.py`, `sw/pynq/test_driver_mock.py`, `sw/pynq/README.md` |
| **B** blok tasarım + Kademe 3 | 3 | **yeni** `vivado/build_bd.tcl`, `vivado/bd_constraints.xdc`, `k3/` altı (TB, koşucu) |

## 8. Ortak kurallar

- Çalışma dizini kendi worktree'n. **Git komutu çalıştırma** (sandbox `.git`'e yazamaz); commit
  orkestratörde.
- Simülasyon: `python sim/run_tests.py [tb_adı]` (`systolic-array-8x8/` içinden). Bir test yalnız
  PASS satırı yazarsa geçer. Vivado: `C:\Vivado\2025.1\Vivado\bin` (PATH'te yok, mutlak yol).
- Mevcut RTL'i ve testleri "iyileştirme"; yalnız görevin gerektirdiği satırlara dokun, mevcut stile uy.
- Spekülatif özellik, kullanılmayan parametre, olmayacak senaryo için hata yönetimi yazma.
- Golden her zaman saf Python'dan gelir, RTL çıktısından türetilmez.
- Yeni her mekanizma için en az 3 mutasyon (geçici kopyada; commit'lenmez): mutant → hangi test,
  hangi satırla FAIL verdi. Hayatta kalan mutantı gizleme, yaz.
- İş bitince worktree köküne `LANE-RAPOR-<lane>6.md` yaz: değişen dosyalar, koşulan komutlar ve
  **gerçek** çıktı satırları, mutasyon tablosu, ölçülmeyenler, kontrata itirazlar, orkestratöre
  bırakılan tek satırlık ekler. Koşmadığın şeyi "geçti" diye yazma.
