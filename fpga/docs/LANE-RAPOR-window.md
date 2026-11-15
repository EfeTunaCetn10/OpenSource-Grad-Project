# LANE-RAPOR — L1 window (`lane/window`), 2026-10-08

Kapsam: ADR-018 Karar 2'nin "Bedeli" listesindeki 1. ve 2. madde (`C_LOGICAL` /
`C_PHYS_STRIDE` ayrımı), `window_gen`'in frame lifecycle'ı (restart), bunların
testleri ve `model/window_ref.py`'ye physical tile-major modeli.

Worktree: `C:\grad-wt\window`, branch `lane/window`, base commit `0d05e9a`.

## Özet — kötü haber önce

- GÖREV 1-4 bitti. `python sim/run_tests.py` **10/10 PASS**, mutasyon **5/5**,
  `T_CONV2_REPLAY_001` ve restart testleri Python golden modeliyle bit-exact.
- **Timing payı geri gitti ve bunu kendi değişikliğime atfediyorum:**
  sentez WNS **+1,203 → +0,897 ns**, post-route WNS **+0,920 → +0,348 ns**.
  Conv1 100 MHz'i hâlâ kapatıyor (post-route PASS, DRC temiz, hold payı
  +0,050 → +0,082 ns ile iyileşti) ama brief'in istediği +1,0 ns sentez payını
  **tutmuyorum**.
- Kritik yol her üç koşuda da `layer_ctrl → weight_feeder` komut yolu, benim
  dosyalarımda değil; logic level 10'dan 10'a sabit, kayıp tamamen routing'de.
  Üç ayrı post-route koşusuyla ölçtüm ve "iki yeni port placement'ı kaydırdı"
  hipotezini kontrol deneyiyle **çürüttüm** — detay bölüm 3'te.

---

## 1. Ne yazdım

| Dosya | Satır (önce → sonra) | diff |
| --- | --- | --- |
| `rtl/line_buffer.sv` | 240 → 343 | +137 / −34 |
| `rtl/window_gen.sv` | 344 → 482 | +155 / −17 |
| `rtl/conv1_top.sv` | 348 → 369 | +33 / −12 |
| `tb/tb_window_gen.sv` | 414 → 805 | +402 / −11 |
| `model/window_ref.py` | 86 → 308 | +222 / −0 |

`filelist.f` değişmedi: yeni dosya eklemedim, dolayısıyla yeni satır gerekmedi.

### GÖREV 1 — `C_LOGICAL` / `C_PHYS_STRIDE`

`line_buffer` ve `window_gen` artık iki parametre alıyor; `C_PHYS_STRIDE`
default'u `C_LOGICAL`, yani conv1 (3/3), dense conv2 (6/6) ve FC-as-1x1 (400/400)
davranışı birebir aynı kalıyor.

- `ROW_BYTES = IN_W * C_PHYS_STRIDE` (physical).
- `rd_byte_index = rd_col * C_PHYS_STRIDE + rd_ch` (logical koordinattan
  physical offset). `C_PHYS_VALUE` bir localparam, yani sabit çarpım —
  değişken bölme/modulo yok, değişmez ihlal edilmedi.
- Geçerlilik: `rd_ch < C_LOGICAL`.
- `window_gen`: `K_LEN = C_LOGICAL * K_H * K_W`, `CI_W`/`LAST_CI`/`CH_W` hepsi
  `C_LOGICAL`'dan. Conv2'de K = 150, 200 değil — bu testle kanıtlandı (aşağıda).
- `rd_ch` portunun genişliği `$clog2(C_LOGICAL+1)`.

**Guard — iki katmanlı, ikisi de her iki modülde:**

1. `ifndef SYNTHESIS` içinde `$fatal`.
2. Sentezde de geçerli derleme-zamanı kontrolü: `generate if (C_PHYS_STRIDE <
   C_LOGICAL)` içinde var olmayan bir modül instantiate ediliyor
   (`illegal_parameters_C_PHYS_STRIDE_below_C_LOGICAL`). Yasal
   parametrelendirmede generate hiç elaborate edilmiyor, yani sıfır maliyet.
   **Bunu ölçtüm**, varsaymadım: `C_LOGICAL=6, C_PHYS_STRIDE=4` ile bir wrapper
   yazıp çalıştırdım, XSim elaboration şu hatayı verdi:

   ```
   ERROR: [VRFC 10-2063] Module <illegal_parameters_C_PHYS_STRIDE_below_C_LOGICAL>
   not found while processing module instance <g_bad_stride.u_guard>
   [.../rtl/window_gen.sv:108]
   ERROR: [XSIM 43-3322] Static elaboration ... failed.
   ```

   `$fatal`/`$error`'ın Vivado sentezinde onurlandırılacağına güvenmek
   istemedim; çözülemeyen modül referansı her iki araçta da hard error.

### GÖREV 2 — frame lifecycle / restart

- `window_gen`'e `restart` girişi ve sticky `restart_error` çıkışı.
- `line_buffer`'a `clear` girişi.
- Kabul koşulu: `restart_ok = restart && (state == ST_DONE || restart_idle)`,
  `restart_idle = (state == ST_INPUT) && !frame_started`. `frame_started` bir
  input beat kabul edildiğinde veya ST_INPUT'tan çıkıldığında kalkıyor; bu
  olmadan iki output satırı arasındaki ST_INPUT boşluğu "reset sonrası idle"
  ile karışırdı ve frame ortasındaki restart yanlışlıkla kabul edilirdi.
- Kabul edilen restart `out_y`, `tile_x`, `k/ci/kh/kw`, bütün gather
  sayaçlarını, `gather_reg`'i, `out_base_row`/`tile_base_col`'u ve
  `frame_started`'ı **reset değerlerine** çekiyor; aynı cycle'da `clear`
  line_buffer'ın write pointer'larını (`write_row`, `write_byte_in_row`,
  `write_ring_slot`, `write_bank`, `write_addr`), `rows_written`,
  `frame_done`, `beat_pending`, `row_pause`, `beat_lane`'i sıfırlıyor.
- Reddedilen restart hiçbir şeye dokunmuyor, `restart_error` sticky yanıyor
  (sadece `rst_n` temizliyor).

**Ring içeriğini SİLMİYORUM — gerekçe RTL'de yorum olarak yazılı:**
okuma `rd_row < rows_written` ile kapılı ve `rows_written` sıfırlanıyor, yani
bir satır tamamen yeniden yazılmadan o slot okunamıyor (`rows_written` ancak
satırı bitiren byte'ta artıyor, slot hiç yarı-geçerli olmuyor). Ayrıca
`rd_byte_index <= ROW_BYTES-1` (çünkü `rd_col < IN_W` ve
`rd_ch < C_LOGICAL <= C_PHYS_STRIDE`), yani satırın son byte grubundaki
artık byte'lar — yeniden yazmanın dokunmadığı tek yer — hiç adreslenemiyor.
8 × `MEM_DEPTH` byte süpürmek kendi state machine'ini ve multi-cycle busy
handshake'ini gerektirirdi. Yarım silinmiş ring gerçekten tehlikeli olan
seçenek; ya hep ya hiç, burada hiç.

`clear` ayrıca `s_ready`'yi ve `write_fire`'ı o cycle için kapatıyor, böylece
bir beat handshake'te kabul edilip clear tarafından düşürülemiyor.

Yeni SVA'lar: `a_clear_resets_write_side` (line_buffer),
`a_restart_rewinds_everything`, `a_refused_restart_is_inert`,
`a_refused_restart_keeps_rows`, `a_restart_error_sticky` (window_gen).
Mevcut `a_registered_read_valid` korundu — `clear` branch'i `rd_valid`'i
bilinçli olarak sıfıra ZORLAMIYOR, yoksa clear'ın kendisi o kontratı kırardı
(gerekçe dosyada yazılı).

### `conv1_top`

- Parametre listesine `C_PHYS_STRIDE = C_IN` eklendi; `u_window`'a
  `.C_LOGICAL(C_IN)`, `.C_PHYS_STRIDE(C_PHYS_STRIDE)` geçiliyor.
- `restart` girişi ve `restart_error` çıkışı top boundary'sine çıktı.
  `layer_ctrl`'e **dokunulmadı**, `error_flags` onda kaldı.
- Üstteki eskimiş yorum ("C_LOGICAL/C_PHYS_STRIDE split ... not written yet")
  düzeltildi.

### GÖREV 4 — `model/window_ref.py`

Mevcut `window_stream` dense modeli **değişmedi**. Yanına eklendi:

- `physical_addr(h,w,c,H,W)` — ADR'nin formülü birebir.
- `pack_physical_frame(...)` — dense HWC → padded tile-major, padding lane'leri
  nonzero sentinel (`0xAA`/`0xBB`). `c_phys_stride == 8` durumunda satır-stride
  paketlemesinin ADR adresiyle aynı olduğunu assert ediyor (Aşama 1'de tek
  channel tile var; `c_logical > 8` ADR-018 "Bedeli" 5 gereği Aşama-2 blocker'ı).
- `physical_window_stream(...)` — physical adresleme, logical kanal aralığı,
  logical K.
- `stream_checksum(...)` — sıraya duyarlı 32-bit özet; testbench'i Python
  modeline bir SAYI ile bağlıyor, iki ayrı yazılmış koordinat fonksiyonuna
  değil.

Çalıştırıldı, gerçek çıktı:

```
$ python model/window_ref.py
PASS window_ref
CONV2_PHYS_CHECKSUM = 0x9AF4F8F4
CONV2_DENSE_CHECKSUM = 0x9AF4F8F4
PASS window_ref physical tile-major (K=150, no sentinel leak)
```

İki checksum'ın eşit olması physical ve dense modelin bit-exact aynı stream'i
verdiğinin kanıtı. Self-check ayrıca `c_phys_stride < c_logical`'ın `ValueError`
attığını, frame'in 1568 byte olduğunu, tile başına k dizisinin tam `range(150)`
olduğunu ve stream'de hiç sentinel olmadığını doğruluyor.

---

## 2. Testler — gerçek çıktı

### Tam regression

```
$ python sim/run_tests.py
[xvlog] compiling 22 file(s)

  tb_axi_lite_regs        PASS
  tb_compute_engine       PASS
  tb_conv1_top            PASS
  tb_layer_ctrl           PASS
  tb_pe_os                PASS
  tb_requant_array        PASS
  tb_requant_unit_num     PASS
  tb_requant_unit_timing  PASS
  tb_weight_feeder        PASS
  tb_window_gen           PASS

10/10 passed
```

Base commit'te de 10/10 idi; conv1 (3/3), dense conv2 (6/6), FC (400) ve
`tb_conv1_top` testlerinin hepsi değişmeden yeşil kaldı.

### `tb_window_gen` içindeki yeni testler

`tb_window_gen` artık dördüncü bir instance taşıyor: `u_c2p`, `C_LOGICAL=6`,
`C_PHYS_STRIDE=8`, `IN_H=IN_W=14`, `K_H=K_W=5`, `STRIDE=1`, `PAD=0`.
Physical row 112 B, ring 5×112 = 560 B, frame 1568 B = 196 input beat,
`OUT_H=OUT_W=10`, 20 tile × 150 beat = 3000 beat.

`u_c2` (dense 6/6) ve `u_c2p` (padded 6/8) aynı geometriyi ve aynı logical
kanal sayısını paylaşıyor, yani iki farklı byte düzeninden AYNI 3000 beat'lik
stream'i vermek zorundalar. Ayrımın bütün amacı bu.

Gerçek `INFO` çıktısı (`--verbose`):

```
INFO c2p pattern=0 slot=0 restart_at=0: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=0
INFO c2p pattern=1 slot=1 restart_at=0: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=0
INFO c2p backpressure invariance: all 3000 beats identical
INFO c2p pattern=0 slot=0 restart_at=0: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=0
INFO c2p pattern=1 slot=1 restart_at=0: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=0
INFO restart replay: all 3000 beats identical
INFO c2p pattern=2 slot=0 restart_at=0: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=0
INFO c2p pattern=0 slot=1 restart_at=0: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=0
INFO restart replay: all 3000 beats identical
INFO c2p pattern=0 slot=0 restart_at=0: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=0
INFO c2p pattern=0 slot=1 restart_at=1200: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=1
INFO mid-frame restart refused: all 3000 beats identical
INFO c2p pattern=1 slot=1 restart_at=1200: 3000 beats, 20 tiles of 150, 196 input beats, checksum 9af4f8f4, restart_error=1
INFO mid-frame restart refused: all 3000 beats identical
PASS tb_window_gen
```

**`T_CONV2_REPLAY_001`** — ADR-018'in explicit istediği test:

- Padding byte'ları (kanal 6, 7) nonzero sentinel: `0xAA` / `0xBB`.
  Gerçek data `0..159` aralığında üretiliyor (`(... * 53 + 19) % 160`), yani
  sentinel değerleri data olarak **imkânsız**. Testbench bunu varsaymıyor,
  frame'i tarayıp kanıtlıyor (`FAIL frame2p sentinel value collides...`).
- Tile başına TAM 150 beat: `tile_beats != 150` kontrolü + `exp_k` dizisinin
  `0..149` olarak ilerlediği + toplam 20 tile kontrolü. Ölçülen: 20 × 150.
- Sentinel sızıntısı: ayrı bir sürekli monitor her `negedge`'de `m_valid`
  yüksekken 8 lane'in hepsini tarıyor — "kabul edilen beat"lerde değil, **her
  cycle'da**. Hiç sentinel görülmedi. (Monitor kendi sayacını sürüyor;
  `errors` tek procedural driver'da kalıyor, dünkü XSim kuralı.)
- Golden karşılaştırma: RTL'in ürettiği stream üzerinden hesaplanan 32-bit
  checksum `0x9AF4F8F4`, `python model/window_ref.py`'nin bastığı sabitle
  birebir aynı. Bu bit-exact bir karşılaştırma: `(k, active_cols, 8 byte)`
  üçlülerinin tamamı, sırayla, özetin içinde.
- Byte-byte koordinat modeli karşılaştırması da duruyor (`c2p_expected`),
  physical stride 8 ile.

**Restart testleri:**

- `done` sonrası `restart` pulse'u → aynı frame yeniden stream edildi →
  3000 beat'in tamamı (data + `active_cols` + `k`) birincisiyle BİREBİR aynı.
  İki kez koşuldu, farklı `m_ready` desenleriyle: (0,1) ve (2,0).
- Frame ORTASINDA (beat 1200/3000) `restart` → `restart_error` yandı ve frame
  bozulmadan sonuna kadar gitti; 3000 beat temiz referansla birebir aynı.
  İki `m_ready` deseniyle koşuldu.
- Reset sonrası idle'da `restart` → kabul edildi, no-op, `restart_error`
  yanmadı ve sonraki frame kusursuz. (`restart_idle` dalı aksi hâlde hiç
  test edilmemiş olurdu.)
- `reset_all()` sonrası `restart_error`'ın temizlendiği de kontrol ediliyor.

**Backpressure:** her senaryo en az iki `m_ready` deseniyle koştu.
`pattern=0` kesintisiz, `pattern=1` `prng&7 != 0` (~%87 ready, input de
boşluklu), `pattern=2` `prng&3 == 0` (~%25 ready). Replay senaryosu üç desenin
hepsini gördü ve beat dizisinin desene göre değişmediği ayrıca
`c2p backpressure invariance` ile kanıtlandı.

### Testbench'te bulunan gerçek hata (RTL değil, TB)

İlk koşuda restart'tan sonraki ikinci geçişin ilk tile'ının lane 0'ı yanlıştı
(6 beat / 3000). Tahmin etmeyip instrument ettim; sebep **RTL değil,
testbench'in input handshake deyimiydi**:

Dosyadaki eski task'lar kabulü "`s_ready` yeniden yükseldi" diye çıkarıyor.
Bu sadece restart olmadığı için çalışıyor: frame'in son beat'inden sonra
`line_buffer` `frame_done`'ı kaldırıyor ve `s_ready` bir daha hiç yükselmiyor,
dolayısıyla o deyim son beat'in indiğini göremiyor ve `s_valid`'i asserted
bırakıyor. Restart `frame_done`'ı temizleyince `s_ready` yükseliyor ve
generator o artık 197. beat'i yeni frame'in 0. beat'i olarak **haklı olarak**
yutuyor — AXIS'te master TVALID'i geri çekemez, yani bu master tarafında bir
frame-kontratı ihlali, RTL defect'i değil. Yeni task handshake'i clock'ta
örnekliyor (`c2p_accept`), artık her geçişte tam 196 input beat kabul
edildiğini ve frame sonunda `s_valid`'in düştüğünü de assert ediyor.

Bunu bir açık uç olarak da yazıyorum (bölüm 5), çünkü entegrasyonda gerçek
bir tuzak.

---

## 3. Sentez — A/B, tahmin değil ölçüm

WNS düştü. Saklamıyorum ve nedenini ölçerek atfediyorum: aynı script'i
`0d05e9a`'nın `git archive`'ından çıkarılmış **değiştirilmemiş** RTL üzerinde
de koştum (`C:\grad-synth-base`), yani iki sayı aynı araç ve aynı günün aynı
makinesinden.

`vivado -mode batch -source vivado/check_synth_conv1.tcl`, top `conv1_top`,
part `xc7z020clg400-1`, out-of-context:

| | Base `0d05e9a` | Bu lane | Δ |
| --- | ---: | ---: | ---: |
| Sentez WNS | **+1,203 ns** | **+0,897 ns** | **−0,306 ns** |
| `conv1_top` Total LUT | 5013 | 4994 | −19 |
| `conv1_top` FF | 4033 | 4035 | +2 |
| RAMB36 / RAMB18 | 16 / 0 | 16 / 0 | 0 |
| DSP48 | 80 | 80 | 0 |
| LUTRAM (hier. sütunu) | 110 | 110 | 0 |
| `u_window` toplam LUT | 347 | 323 | −24 |
| `u_window` FF | 279 | 281 | +2 |
| `u_line_buffer` LUT | 314 | 289 | −25 |
| `u_line_buffer` FF | 169 | 169 | 0 |

Her iki koşu da gate'i geçti: `PASS: conv1_top synthesized, 80 DSP48, weight
path present`.

**Kritik yol her iki koşuda da BENİM dosyalarımda değil:**

| | Base | Bu lane |
| --- | --- | --- |
| Source | `u_ctrl/cfg_k_reg_reg[0]/C` | `u_ctrl/cfg_tile_reg_reg[1]/C` |
| Destination | `u_weights/beats_accepted_reg[0]/CE` | `u_weights/beats_accepted_reg[0]/CE` |
| Data path | 8,544 ns (logic 3,256 / route 5,288) | 8,850 ns (logic 3,259 / route 5,591) |
| Logic levels | 10 | 10 |

Yani: logic delay neredeyse birebir aynı (3,256 → 3,259 ns), logic level sayısı
aynı (10), fark tamamen **unplaced route tahmininde** (5,288 → 5,591 ns). Yol
`layer_ctrl → weight_feeder` komut yolu — ADR-018'in dün "sıradaki limiter"
diye kaydettiği yolun aynısı, ve sahipliğim dışındaki iki dosyada.
`report_timing_summary -max_paths 20` çıktısındaki **20 yolun hepsi** bu
`u_ctrl → u_weights` yolu; `u_window` veya `u_line_buffer` uçlu tek bir yol
bile ilk 20'ye girmiyor, yani window yolunda en az **+1,507 ns** pay var.

Dürüst okuma: `-flatten_hierarchy rebuilt` ile sentez global karar veriyor;
netlist değişince hangi `cfg_*` biti en kötü olduğu ve o yolun fanout/route
tahmini kayıyor. Benim eklediğim mantık window yolunda ve o yol KÜÇÜLDÜ
(−24 LUT). Ama **brief'in istediği en az +1,0 ns sentez payını tutmuyor**:
+0,897 ns. Bu yüzden post-route ölçümünü de koştum, çünkü +0,075 ns'in
implementation'ı geçmediği dersi dünden kayıtlı.

### Post-route (`vivado/check_impl_conv1.tcl`) — asıl sayı, ve kötü haber burada

Aynı A/B'yi post-route'ta da yaptım. Base koşusu dünkü sayıyı **birebir**
yeniden üretti (+0,920 ns setup / +0,050 ns hold, 4918 LUT, 4033 FF), yani
ölçüm deterministik ve karşılaştırma geçerli.

| | Base `0d05e9a` | Bu lane | Δ |
| --- | ---: | ---: | ---: |
| Post-route setup WNS | **+0,920 ns** | **+0,348 ns** | **−0,572 ns** |
| Post-route hold WHS | +0,050 ns | **+0,082 ns** | +0,032 ns |
| `conv1_top` LUT (impl) | 4918 | 4904 | −14 |
| `conv1_top` FF (impl) | 4033 | 4035 | +2 |
| RAMB36 / DSP48 | 16 / 80 | 16 / 80 | 0 |
| DRC | 0 error | 0 error | — |

Her iki koşu da gate'i geçiyor (`PASS: conv1_top routes and closes 100 MHz`),
yani conv1 100 MHz'i hâlâ kapatıyor — ama **pay 0,572 ns daraldı.** Bunu
"benim değil" diye geçiştirmiyorum, ölçüp ayrıştırıyorum:

| | Base post-route | Bu lane post-route |
| --- | --- | --- |
| Source | `u_ctrl/cfg_tile_reg_reg[0]/C` | `u_ctrl/cfg_tile_reg_reg[1]/C` |
| Destination | `u_weights/beats_accepted_reg[0]/CE` | `u_weights/beats_accepted_reg[6]/CE` |
| Data path | 8,791 ns | 9,363 ns |
| — logic | 3,391 ns (38,6%) | 3,406 ns (36,4%) |
| — route | 5,400 ns (61,4%) | **5,957 ns (63,6%)** |
| Logic levels | 10 (3×CARRY4) | 10 (3×CARRY4) |

Yani: logic derinliği aynı (10 seviye, aynı CARRY4 sayısı), logic gecikmesi
neredeyse aynı (+0,015 ns), **regresyonun tamamı routing'de (+0,557 ns)** ve
yol tamamen `layer_ctrl → weight_feeder` komut yolunda — benim dokunmadığım
iki dosyada. İlk 20 yolun hepsi bu yol; `u_window`/`u_line_buffer` uçlu bir
yol ilk 20'ye girmiyor.

**Hold payı iyileşti** (+0,050 → +0,082 ns), yani eklediğim iki kısa
kombinasyonel yol hold tarafını kötüleştirmedi.

**Mekanizma hipotezi ve kontrol deneyi.** Benim netlist'e katkım +2 FF,
−14 LUT ve **iki yeni top-level port** (`restart`, `restart_error`).
Out-of-context implementation'da top-level portlar yerleşim çapası; iki port
eklemek bütün placement'ı kaydırabilir ve %64'ü routing olan bir yolda bu
yarım nanosaniye eder. Bunu izole etmek için üçüncü bir koşu yaptım:
**değiştirilmemiş base RTL + iki işlevsiz top-level port**
(`probe_in`/`probe_out`, aralarında tek bir `assign`), başka hiçbir fark yok.

**Kontrol deneyi hipotezi ÇÜRÜTTÜ:**

| Koşu | Post-route WNS | WHS | LUT | FF | Kritik yol kaynağı |
| --- | ---: | ---: | ---: | ---: | --- |
| Base `0d05e9a` | +0,920 ns | +0,050 ns | 4918 | 4033 | `cfg_tile_reg_reg[0]` |
| Base + 2 işlevsiz port | **+0,920 ns** | +0,050 ns | 4918 | 4033 | `cfg_tile_reg_reg[0]` |
| Bu lane | **+0,348 ns** | +0,082 ns | 4904 | 4035 | `cfg_tile_reg_reg[1]` |

İki fazladan top-level port, base'i **hiç** değiştirmiyor: aynı WNS, aynı WHS,
aynı LUT/FF, aynı kritik yol, aynı data path delay (8,791 ns). Yani port sayısı
değil.

**Dolayısıyla dürüst sonuç: 0,572 ns'lik post-route kaybı benim değişikliğime
atfedilir.** Mekanizma mantık derinliği değil — eklediğim hiçbir mantık o yolun
üzerinde değil, logic level 10'dan 10'a sabit, logic delay +0,015 ns. Mekanizma
şu: `layer_ctrl → weight_feeder` komut yolu zaten 10 seviye ve %61 routing ile
sınırdaydı; netlist'teki (+2 FF / −14 LUT / yeniden yapılandırılmış window
mantığı) değişiklik placer'ın kararlarını kaydırdı ve o yolun routing'i
5,400 → 5,957 ns oldu. Bu yol, ADR-018'in dün "sıradaki limiter" diye
kaydettiği yolun aynısı ve sahipliğim dışında.

**Brief'in istediği en az +1,0 ns sentez payını tutamıyorum** (+0,897 ns) ve
post-route payı +0,920 → +0,348 ns'e indi. Kendi dosyalarımda bu payı geri
getirebileceğim bir şey yok: o yolun üzerinde benim tek bir LUT'um bile yok.
Payın gerçekten geri gelmesi için `layer_ctrl`'ün `cfg_tile_idx`/`cfg_k`
çıkışından `weight_feeder`'ın adres toplayıcısına giden yolun bir register ile
kesilmesi gerekiyor (10 logic level + 3 CARRY4 ikiye bölünür). Bu iki dosya da
başka lane'lerin sahipliğinde — orkestratör kararı.

Ham kanıt, isteyen tekrar üretebilsin diye bıraktım:
`C:\grad-synth-base` (pristine base), `C:\grad-port-probe` (base + 2 port),
ve bu worktree'nin `systolic-array-8x8/reports/` klasörü (bu lane).

**Yeni kombinasyonel yol ekledim mi:** evet, iki tane ve ikisi de kısa.
(1) `restart` → `restart_ok` → `lb_clear`, oradan `s_ready` ve `write_fire`;
`s_ready` zaten `state`'e kombinasyonel bağlıydı, eklenen tek bir AND girişi.
(2) `restart_ok`, state machine'in next-state mantığına bir priority mux
seviyesi ekliyor. Hold payı dün inceydi (+0,050 ns), bu yüzden post-route
hold sayısını da yukarıda ayrıca raporluyorum.

---

## 4. Mutasyon disiplini — 5/5

Her mutant tek başına enjekte edildi, `python sim/run_tests.py tb_window_gen`
koşuldu, sonra dosya byte-exact geri yüklendi (script:
scratchpad'deki `mutate.py`, occurrence-index'li exact replace + backup).

| # | Sınıf | Mutasyon | Sonuç |
| --- | --- | --- | --- |
| M1 | off-by-one | `line_buffer`: `rd_byte_index = rd_col*C_PHYS_VALUE + rd_ch` → `+ rd_ch + 1'b1` | **YAKALANDI** |
| M2 | ters polarite | `window_gen`: `restart_bad = restart && !restart_ok` → `restart && restart_ok` (kabul edilen restart hata bayrağı kaldırır, reddedilen kaldırmaz) | **YAKALANDI** |
| M3 | yanlış bit alanı | `line_buffer`: `rd_bank_calc = rd_byte_index[2:0]` → `rd_byte_index[3:1]` | **YAKALANDI** |
| M4 | kaçırılmış backpressure | `window_gen`: `ST_OUTPUT`'ta `if (m_ready)` → `if (1'b1)` | **YAKALANDI** |
| M5 | yanlış reset değeri | `line_buffer`: `clear` dalında `rows_written <= '0` → `<= '1` | **YAKALANDI** |

```
CAUGHT  M1 off-by-one: physical byte index +1
CAUGHT  M2 reversed polarity: restart_error flags the ACCEPTED restart
CAUGHT  M3 wrong bit field: bank select takes rd_byte_index[3:1]
CAUGHT  M4 missed backpressure: ST_OUTPUT advances without m_ready
CAUGHT  M5 wrong reset value: clear leaves rows_written all-ones

5/5 mutants caught
```

Mutasyonlardan sonra `git diff --numstat` mutasyon öncesiyle birebir aynı
(`line_buffer` 137/34, `window_gen` 155/17), yani geri alma temiz.

---

## 5. Açık kalanlar ve emin olmadığım şeyler

1. **TIMING PAYI GERİ GİTTİ ve bu benim değişikliğime atfedilir.** Sentez
   +1,203 → +0,897 ns, post-route +0,920 → +0,348 ns. Brief'in istediği
   +1,0 ns sentez payını **tutmuyorum.** Conv1 100 MHz'i hâlâ kapatıyor
   (post-route PASS, DRC 0 error, hold payı +0,050 → +0,082 ns iyileşti) ama
   setup payı dörtte birine indi.

   Ne olduğunu ölçtüm, tahmin etmedim: üç ayrı post-route koşusu (base,
   base+2 port, bu lane). Port sayısı hipotezini kontrol deneyi çürüttü.
   Regresyonun tamamı `layer_ctrl → weight_feeder` komut yolunun
   **routing'inde** (5,400 → 5,957 ns); logic level 10'dan 10'a sabit, logic
   delay +0,015 ns, ve o yolun üzerinde benim hiçbir mantığım yok. Yani
   mekanizma: zaten sınırda olan (%61 route, 10 seviye, 3 CARRY4) bir yolun
   placement'a aşırı duyarlı olması.

   **Emin olmadığım şey:** bu kaybın ne kadarının kaçınılmaz olduğu. Hangi
   alt-değişikliğin (C_LOGICAL/C_PHYS_STRIDE mi, restart mantığı mı) daha çok
   kaydırdığını ayrı ayrı ölçmedim — ikisi de teslim kapsamında zorunlu
   olduğu için ayrıştırmanın karar değiştirmeyeceğini düşündüm, ama bu bir
   yargı, ölçüm değil. Gerçek çözüm o yolu register ile kesmek ve bu
   `layer_ctrl` + `weight_feeder` sahiplerinin işi; orkestratör kararı.

2. **`restart` artık top boundary'sinde kombinasyonel bir input→output yolu
   yaratıyor:** `restart` → `restart_ok` → `lb_clear` → `s_ready`. Kısa bir
   yol ve kritik değil, ama `s_ready` AXIS için kombinasyonel kalmak zorunda
   olduğundan bu yolu register'layarak kaldıramadım. `!clear` terimini
   bilerek tuttum: olmadığı durumda clear cycle'ında kabul edilen bir beat
   sessizce DÜŞÜRÜLÜRDÜ (clear dalı `beat_pending`'i sıfırlıyor), terim
   varken ise hiç kabul edilmiyor — sessiz veri kaybı yerine geri basınç.
   Block design'a girildiğinde bu boundary yolu kontrol edilmeli.

3. **Restart + askıda kalmış `s_valid`.** `restart`, upstream'in hâlâ asserted
   tuttuğu bir beat'i iptal ETMİYOR ve AXIS'e göre edemez de. Frame kontratı
   "tam 196 beat" olduğu için 197. beat master tarafında protokol hatasıdır,
   ama entegrasyonda (act_buffer → conv1_top) **sequencer restart'ı ancak
   upstream'de kabul edilmemiş beat yokken vermeli**. Bunu RTL'de bir
   assertion'a bağlamadım: `s_valid`'i restart kapısına sokmak yeni bir
   kombinasyonel yol ve yeni bir refuse sebebi demek olurdu, ve bu kararın
   `act_buffer` kontratı netleşmeden verilmesi doğru olmaz. Faz-2'de
   konuşulmalı.

4. **`conv1_top`'ta `C_IN` adını `C_LOGICAL`'a çevirmedim.** `tb_conv1_top`
   (benim dosyam değil) `.C_IN(C_IN)` geçiyor; yeniden adlandırma sahipliğim
   dışındaki bir dosyayı kırardı. Bu yüzden `conv1_top`'ta `C_IN` = logical
   kalıp yanına `C_PHYS_STRIDE = C_IN` eklendi ve yorumda bu açıkça yazıldı.
   Ayrım taşındı ama isimlendirme submodüllerle simetrik değil. Faz-2'de
   `tb_conv1_top` ile birlikte düzeltilmesi daha temiz olur.

5. **SystemVerilog default port value kullandım** (`input logic restart = 1'b0`
   — `window_gen`, `line_buffer`, `conv1_top`). Gerekçe: bu port olmadan yazılmış
   `tb_conv1_top` bağlamadığı input'u `'z` bırakıyor, `'z` `!clear` üzerinden
   `s_ready`'yi x'leyip `tb_conv1_top`'u hard kilitliyordu. XSim'in default'u
   onurlandırdığını ayrı bir mini test ile ölçtüm, Vivado 2025.1 sentezi de
   `conv1_top`'u hatasız/critical-warning'siz sentezledi. Yine de bu, aracın
   desteğine dayanan bir kalıp; block design'a girildiğinde IP paketleyicinin
   portu nasıl gördüğü kontrol edilmeli.

6. **Ring içeriği `clear`'da silinmiyor.** Gerekçe RTL'de yazılı ve
   `rows_written` kapısına + `rd_byte_index <= ROW_BYTES-1` sınırına dayanıyor;
   ikisini de testler dolaylı doğruluyor (M5 mutantı tam bu kapıyı kırıyor ve
   yakalanıyor). Doğrudan "ring'de eski frame'in byte'ı var ve okunamıyor"
   diye bir hedefli test YAZMADIM; replay testi iki frame aynı data olduğu
   için bunu ayırt etmiyor. **İki FARKLI frame ile replay testi eksik** —
   pass B'ye başka bir frame verip karşılaştırmak bu argümanı doğrudan
   sınardı. Zaman yetti ama kapsamı büyütmemek için eklemedim; eksikliği
   bilinçli ve burada yazılı.

7. **`PAD != 0` hiç test edilmedi**, ne eskiden ne şimdi. `restart` dalı
   `out_base_row <= -PAD` yazıyor, yani kalıp korunuyor, ama Aşama-1 kontratı
   `PAD=0` ve ben de bu varsayımı sürdürdüm.

8. **`C_LOGICAL > 8` (çok channel tile'lı physical layout) desteklenmiyor** ve
   bu bilinçli: ADR-018 "Bedeli" 5 bunu Aşama-2 blocker'ı olarak kaydetti.
   `model/window_ref.py` ADR adres formülünün satır-stride paketlemesiyle
   aynı olduğunu sadece `c_phys_stride == 8` için assert ediyor; daha derin
   bir tile ekseni ne modelde ne RTL'de var.

9. **`T_LAYOUT_ADDR_001` ve `T_FC1_ORDER_001` bu lane'de yazılmadı.** ADR-018
   onları yeni test kimlikleri arasında sayıyor ama bana verilen görev
   `T_CONV2_REPLAY_001` + restart; ilki ara aktivasyon writer'ının (L2),
   ikincisi ağırlık export'unun işi.

10. **Timing tahmini vs gerçek:** sentez sayıları `-mode out_of_context` ve
   ideal clock ile. Dün kaydedilen "hold payı +0,050 ns ince, block design'da
   gerçek clock ağacıyla yeniden ölçülmeli" notu aynen geçerli, benim
   eklediğim iki kombinasyonel yol bu notu daha da önemli yapıyor.

---

## 6. Sahipliğim dışındaki dosyalar

RTL/TB/model tarafında sahipliğim dışında **hiçbir dosyayı değiştirmedim**.
`filelist.f` ve `layer_ctrl.sv` dokunulmadı, `tb_conv1_top.sv` dokunulmadı,
`main` dokunulmadı, merge yapılmadı.

Tek istisna, benim yazmadığım bir değişiklik: **`systolic-array-8x8/clockInfo.txt`**
Vivado koşuları sırasında araç tarafından yeniden yazıldı (tek satır,
sadece tarih damgası: `Wed Oct 7 22:18:55` → `Thu Oct 8 11:43:39`). Bunu
`git checkout` ile geri aldım, commit'e girmiyor. Bu dosya bir Vivado
artefaktı ve `.gitignore`'a alınması gerekebilir — ortaköre not.
