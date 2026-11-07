# LANE-RAPOR-P3 — test kimliği izlenebilirliği, sistem regression'ı (R5, R6)

Dal `lane/p3-testid`, worktree `C:\grad-wt\p3`, taban `faz5-test` @ 8820c73. RTL ve mevcut testler değişmedi.

## Dosyalar

| Dosya | Değişiklik |
|---|---|
| `TEST-MATRISI.md` | yeni: kontrat `T_*` kimliği -> test / PASS satırı / durum |
| `systolic-array-8x8/model/gen_sys_vectors.py` | yeni: `smoke/gen_smoke.py` uyarlaması + `gen_bp`, `gen_ovf`; saf Python golden; `sim/vectors/sys_*.mem` |
| `systolic-array-8x8/tb/tb_sys_chain.sv` | yeni: S1, S2, S3, S5, S6 + `T_MEM_PINGPONG_001`, `T_NUM_CONV_001` |
| `systolic-array-8x8/tb/tb_sys_faults.sv` | yeni: S7b, S7d (yeni), S4, S7a, S7c + `T_RST_001` (R1, R2, R3) |
| `systolic-array-8x8/tb/tb_sys_bp.sv` | yeni: `T_AXI_BP_001` |
| `systolic-array-8x8/tb/tb_sys_ovf.sv` | yeni: `T_NUM_OVF_001` |
| `systolic-array-8x8/sim/run_tests.py` | tek satır (orkestratöre: merge edilecek satır, aşağıda) |

`smoke/` aynen duruyor.

### `VECTOR_GENERATORS` satırı (orkestratör için)

`gen_fc_vectors` ile `gen_lenet_vectors` arasına (lenet son kalmalı):

```python
    ("gen_sys_vectors.py", "sys_ovf_done.mem"),
```

Sentinel dosyayı üreticinin yazdığı son dosyadır.

## Kararlar

- **Bölme.** Süre yüzünden dört testbench: zincir (S1-S3, S5, S6), hatalar (S4, S7, reset), backpressure, overflow. Sınır: zincir ~63 s sim, hatalar ~36 s.
- **Smoke'tan farklar.** S4 `tb_sys_faults` içinde S7b'den sonra koşar: S4'ün overflow geçişi boş bir yazma katmanı ister, `tb_sys_faults` conv4'ü S7b'de bir kez tamamlayıp swap'lar. S1'de `configure()` yerine `cfg2()` (bit-bit aynı yazma), tüm katmanlar `load_gp` tablolarından.
- **Her tb kendi yardımcılarını taşır.** Ortak paket yok (tb yardımcıları modül sinyallerine bağlı).
- **PASS satırı.** Alt adımlar `ok ...` (PASS yazmaz), kimlik satırları `PASS T_xxx: ...` yalnızca ilgili hatasız ise, son satır `PASS tb_sys_*` yalnızca `errors==0` ise. Hata satırları `SYS-FAIL`/`FAIL`.
- **Golden.** Python, RTL'den okunmaz. `gen_ovf`: wrap32(acc+bias) sonra requant; sat ve ovf bayrakları modelden.

## Test içerikleri

- **`T_NUM_OVF_001`** (`tb_sys_ovf`). 4x4x3 sabit girdi, 3x3 pad0: her piksel `acc_r = 27*X*w_r` tam bilinir, bias sınırın iki yanına konur: +2^31-1 (taşmaz), +2^31 (taşar), -2^31 (taşmaz), -2^31-1 (taşar), acc=0, büyük ağırlıklar, bir normal lane. Dört geçiş: taşmasız bias, sınır bias (lane 1,3,5,6 taşar), aynısı pool açık, W1C sonrası taşmasız. Kontrol: golden word, lane maskesi, beat başına `{m_sat_flat, m_ovf_flat}`, ERROR == 0x04 tam, ERR_DETAIL == 0, DONE ve ABORTED değil, pool'da `m_ovf_flat` = 0 ama ERROR[2] kurulu.
- **`T_AXI_BP_001`** (`tb_sys_bp`). 10x10x8 katman, 13 profil (s_valid/m_ready: hep, %50, %25, %75, burst, m ilk beat'ten 64 cycle tutulur; üçü pool'lu). Kontrol: golden word, tek m_last, tam 100 s_* beat, ERROR/ERR_DETAIL 0, `m_valid && !m_ready` iken tüm m_* yük bitlerinin ve m_valid'in sabitliği, X yok, STALL_IN/STALL_OUT = testbench'in kendi sayımı, m tarafı profilleri gerçekten durdurdu (sayaç > 0).
- **`T_RST_001`** (`tb_sys_faults`). R1: act_buffer -> m_* pass'inde 3. beat'te SOFT_RESET, 3000 cycle sonra idle, hata yok, yeni m_* beat'i yok, FRAME_COUNT=0, sonra yalnızca START ile exact pass. R2: s_* frame'in 200. beat'inde SOFT_RESET, aynı kontroller, sonra yalnızca START ve tile 0 düzlemi exact. R3: m_* pass'inde 10. beat'te rst_n düşer: idle, register imajı gitti (PARAM_STATUS[24]=0), COMMIT'siz START reddedilir (ERROR 0x80), COMMIT+START ağırlık yeniden yüklenmeden exact (ağırlıklar kalır), FRAME_COUNT=1. Ayrıca abort/bayrak sonrası SOFT_RESET'siz kurtarma: S7b, S7d, S4, S7c.
- **`T_MEM_PINGPONG_001`** (`tb_sys_chain`). İzleyici: `buf_sel` yalnızca `act_buffer.swap_ok`'ten bir cycle sonra döner; toplam 9 kabul edilen swap. S1'de conv2'nin 1/3 tile'ından sonra LAYER_SWAP reddedilir (buf_sel sabit, ERROR[7], ERR_DETAIL[8]). Yazılan katman exact ve okunan bank bir önceki katmanı koruyor (L1 1152 word conv2 yazarken, L2, LeNet conv1, v3 conv4). Birim testi (`tb_act_buffer`) çakışma ve swap bütünlüğünü zaten kanıtlıyor; bu sistem düzeyinde tile'lı kanıt.
- **`T_NUM_CONV_001`** (`tb_sys_chain`). Etiketlendi: tüm conv/FC pass'leri Python zincirine bit-exact.

## Regression

`python sim/run_tests.py` (`systolic-array-8x8/`, temiz a�a�, 34 kaynak):

```
20/20 passed
real	5m37.405s
```

16 mevcut + `tb_sys_bp`, `tb_sys_chain`, `tb_sys_faults`, `tb_sys_ovf`, hepsi PASS. Tek test s�releri (sim): chain ~63 s, faults ~36 s, bp ~9 s, ovf ~1 s. `smoke/` ve RTL de�i�medi (taban smoke'u SMOKE PASS, 2 dk 8 s); smoke bu �al��mada yeniden ko�ulmad�.

## Mutasyonlar (scratch kopya, commit'lenmedi, tek başına)

| Mutasyon | Test | Sonuç |
|---|---|---|
| `requant_unit` `s0_ovf_comb = 0` | `tb_sys_ovf` | YAKALANDI: `sat/ovf = 7f/00 expected 7f6a`, ERROR=00 want 04 |
| `s0_ovf_comb` yalnızca pozitif taşma | `tb_sys_ovf` | YAKALANDI: `sat/ovf = 7f/22 expected 7f6a` |
| `conv_m_ready = 1` (register slice) | `tb_sys_bp` | YAKALANDI: ERROR=08, beats=0/100 |
| `act_buffer` swap tamamlanmamış katmanı kabul eder (`wl_full` düşer) | `tb_sys_chain` | YAKALANDI: `S1 early swap refused: buf_sel=0 want 1`, toggle sayımı |
| `dp_rst_n` SOFT_RESET'i içermez | `tb_sys_faults` | YAKALANDI: `R2 good pass ... STATUS=0000002d`, `s_* beats taken=1` |
| `tlast_early = 0` | `tb_sys_faults` | YAKALANDI: S7b `ERROR=40 ERR_DETAIL=8000 (want 10, 2000)` |
| `tlast_late = 0` | `tb_sys_faults` | YAKALANDI: S7d `ERROR=00 (want 20, 4000)` |
| requant yuvarlama toplamı yok | `tb_sys_chain` | YAKALANDI: `S1 L1 bank: 1142 of 1152 stored words differ` |

## Bulgular

RTL kusuru yok. Gözlemler:

1. **Accumulator taşması sistem düzeyinde ulaşılamaz.** INT8 x INT8 ve K <= 1024 ile |acc| <= 2^24. Gözlenebilir taşma acc+bias toplamıdır (ADR-014 S0, `ERR_ACC_OVF`, ERROR[2]). Motor düzeyindeki wrap `T_ENG_WRAP_001` ile `tb_compute_engine`'de. Kontrat "accumulator wrap ve taşma bayrağı" diyor; metin bias toplamına çevrilmeli.
2. **COMMIT'siz START ERROR[7]'yi kurar** (ERR_DETAIL yok) ve bayrak yapışkandır: bir PS, START'tan önce ERROR'u W1C etmezse `wait` döngüsü eski bayrağı hata sanır (testte yaşandı).
3. **SOFT_RESET FRAME_COUNT ve ERR_DETAIL'i sıfırlar**, ağırlıklar ve act_buffer saklı katmanı kalır; rst_n ise register imajını siler, ağırlık BRAM'i kalır.
4. **`T_AXI_BP_001` s_valid tarafı zayıf uyarılır.** Giriş hızı hesapla sınırlı (`s_ready` ~12,5k/13k cycle düşük), bu yüzden s_valid boşlukları DUT'un kendi duraklamalarının içinde kaybolur. Çıkış tarafı gerçekten durdu (bursty: 2000 cycle). Daha yüksek giriş hızı için küçük K'lı (1x1) bir geometri gerekir.
5. Tek LFSR deseni (başlangıç değerleri sabit); S7b yalnızca 100. beat'te.

## Eşleme özeti (`TEST-MATRISI.md`)

- KAPSANDI (kimlik testte): `T_NUM_REQ_001`, `T_REQ_TIMING_001`, `T_REG_PARAM_001`, `T_ACCEL_CTRL_001`, ve yeni beşi `T_NUM_CONV_001`, `T_NUM_OVF_001`, `T_AXI_BP_001`, `T_RST_001`, `T_MEM_PINGPONG_001`.
- İÇERİKLE (test var, kimlik PASS satırında yok): `T_CONV1_E2E_001`, `T_CONV2_REPLAY_001`, `T_LAYOUT_ADDR_001`, `T_ENG_KSTREAM_001`, `T_ENG_SKEW_001`, `T_ENG_WRAP_001`.
- KISMİ: `T_NET_BITEXACT_001` (tam v3 P2'de), `T_FC1_ORDER_001` (tek-hot yok), `T_AXI_LANE_001` (koordinat kodlu test yok; AXIS/DMA kısmı kart).
- KART/ARAÇ: `T_STA_001`, `T_CDC_001`, `T_ML_ACC_001`, `T_AXI_ROW_001` (TKEEP portu yok), `T_AXI_LANE_001` (DMA'ya özgü kısım).

## Açık sorular

1. Mevcut testlerde kimlik PASS satırında olmayanlar (`T_CONV1_E2E_001`, `T_LAYOUT_ADDR_001`, ...) için etiket eklensin mi? Mevcut testlere dokunulmadı.
2. `T_NUM_OVF_001` metni "accumulator" yerine "acc+bias toplamı" diye düzeltilsin mi (bulgu 1)?
3. `T_AXI_LANE_001` için koordinat kodlu bir sistem testi (bir-hot ağırlıkla tek (ky,kx,c) seçimi) istenir mi, yoksa AXIS sarmalayıcıyla birlikte mi?
