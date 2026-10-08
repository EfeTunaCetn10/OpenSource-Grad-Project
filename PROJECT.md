# Proje durumu — FPGA-SoC INT8 CNN hızlandırıcı

Son güncelleme: **2026-10-08**. Bu dosya donanım (RTL) tarafının nerede olduğunu, hangi
kararların kilitli olduğunu ve ML tarafından ne beklendiğini tek yerde toplar.

Hedef: LeNet-5 topolojisinde INT8 CNN inference'ı, **8×8 output-stationary systolic array**
ile, Zynq-7020 (`xc7z020clg400-1`, PYNQ-Z2) üzerinde. Clock hedefi **100 MHz**.

---

## Nerede duruyoruz

**Conv1 uçtan uca çalışıyor ve bit-exact.** `T_CONV1_E2E_001`: 112 tile, 784 output beat ve
784 INT32 accumulator beat, Python golden'ına karşı **bit düzeyinde** eşleşiyor, iki farklı
backpressure deseniyle iki kez.

| Ne | Durum |
| --- | --- |
| XSim regression (`fpga/sim/run_tests.py`) | **13/13 PASS** |
| `conv1_top` sentez WNS | **+0,897 ns** (80 DSP48, 16 RAMB36) |
| `conv1_top` post-route | **+0,348 ns setup / +0,082 ns hold**, DRC temiz |
| `accel_top` sentez WNS | **+1,157 ns** (60 DSP48, 12 RAMB36 — aşağıdaki uyarıya bak) |
| Conv1 frame süresi | 85.232 cycle = **852 µs** @ 100 MHz |

Ölçüm notu: post-route sayısı `conv1_top` için geçerli ve ayrı bir implementation
koşusundan geliyor. **`accel_top` henüz hiç route edilmedi**, yukarıdaki değeri sentez
tahmini olarak oku — bu projede sentez payının implementation'ı geçmediği bir kez yaşandı
(+0,075 ns kapıyı geçip route'u geçememişti).

### Darboğaz array değil, window generator

852 µs'nin kaynağı: window generator beat başına 10 cycle harcıyor (8400 beat), array ise
cycle başına bir beat yutabiliyor. Hızlandırma yolu gather'ı sekiz bankadan paralel okumak
(ring zaten sekiz banka) — Aşama 2'ye bırakıldı, önce doğruluk.

---

## Kilitli kararlar — ML tarafı bunlara uyar

Tamamı `Kontratlar/` altında, her ADR'nin kendi gerekçesi ve "bu kararı geçersiz kılacak şey"
bölümü var. En kritik dördü:

- **[ADR-003] INT8 fixed-point formatı** — `wrap32`, `signed64` requant, half-up rounding,
  `n ∈ [0,63]` shift. Kilitli ve RTL'de implemente.
- **[ADR-011] Ağırlık bellek adresleme** — banka `r = c_out mod 8`, banka-içi adres
  `tile_idx*K + k`, reduction order **`k = ci*(kH*kW) + kh*kW + kw`**.
  Conv ağırlıklarında permütasyon **yok**, bu vaat ayakta.
- **[ADR-016] Aktivasyon tensör düzeni** — byte yerleşimi ve stream semantiği.
- **[ADR-018] K-streaming ve ara aktivasyon düzeni** — 2026-10-07'de fiziksel layout
  kilitlendi: **padded tile-major**,
  `addr = (((c_out >> 3)*H + h)*W + w)*8 + (c_out & 7)`.

ADR-014/015/016 artık "proposed" değil, **implemente ve test edilmiş** durumda
(`requant_array`, `axi_lite_regs`, `accel_top`). Bu repodaki `Kontratlar/` klasörü
2026-09-25'te donmuştu; bu push onu güncelliyor ve **ADR-017 ile ADR-018'i ilk kez** ekliyor.

### FC1 export'u ADR-016'nın one-liner'ı DEĞİL

ADR-018'in padded tile-major kararının yan etkisi. Doğru transform:

```python
w_fc1 = w_fc1.reshape(120, 2, 8, 5, 5).permute(0, 1, 3, 4, 2).reshape(120, 400)
```

Gerekçe, sayısal örnek (`c=8,h=1,w=0` → dense HWC 88, tile-major 240) ve nelerin
**değişmediği** `Kontratlar/2026-10-08 FC1 export transform bildirimi.md` dosyasında.
Conv ağırlık export'u etkilenmiyor — storage layout ile reduction order aynı şey değil.

---

## Açık iş — kim neyi borçlu

### Donanım tarafı (RTL)

1. `layer_ctrl → weight_feeder` komut yolunu register'la. İki bağımsız ölçüm aynı kritik
   yolu gösterdi (`cfg_tile_reg → beats_accepted/CE`); kaybın tamamı routing'de.
2. **`accel_top`'taki `ACTIVE_ROWS` sabitini kaldır.** Şu an `cfg_active_rows` sabit
   sürülüyor (`C_OUT=6`), Vivado da PE satır 6-7'yi buduyor: **20 DSP + 4 RAMB36** eksik.
   Conv1 çalışır ama bitstream'e conv1 gömülü kalır; conv2'nin 16 output kanalı 8 satırlık
   iki tile istiyor. Yukarıdaki `accel_top` payının rahat görünmesinin sebebi de bu budama.
3. `act_buffer`'ı `conv1_top`'a instantiate et (yazıldı ve test edildi, henüz bağlı değil).
4. AXI-Stream wrapper + ağırlık yükleme yolunu PS'ten erişilebilir yap — şu an `w_wr_*`
   ham port, donanımda onu süren bir şey yok. Board bring-up'ın blocker'ı.
5. Blok tasarım (PS + AXI DMA + clock/reset), bitstream, PS tarafı driver.

### ML tarafı

1. **Layout adapter — şu an sahipsiz.** Eğitilmiş INT8 parametreleri ADR-011 banka
   sırasına, ADR-018 tile-major düzenine ve FC1 permütasyonuna çeviren katman. ML tarafı
   bunu açıkça kapsam dışı ilan etti, RTL tarafı da var olduğunu varsayıyor. Aralık
   hedefinin kritik yolu burası: bu olmadan eğitilmiş ağırlık donanıma girmiyor.
2. **İki golden model'in çapraz doğrulaması.** `cnn_pipeline/candidate_integer_forward.py`
   (CHW/OIHW) ve `fpga/model/conv1_ref.py` (donanım layout'u) bağımsız yazılmış iki
   bit-exact referans. Aynı girdide aynı sonucu verdikleri **hiç test edilmedi**. İkisi de
   Python, ikisi de deterministik — yarım günlük iş, projenin en büyük sessiz riski.
   Adapter'ı yazmadan önce yapılmalı, yoksa adapter hangi referansa göre doğru bilinmez.
3. Katman başına requant parametreleri ADR-003/014 formatında: `bias_q`, `M0`, `shift_n`,
   `relu`. RTL testleri şu an random INT8 fixture kullanıyor (bu bilinçli bir seçim,
   milestone'u eğitim teslimine bağlamamak için) — yani accuracy diye bir şey yok.
4. `T_FC1_ORDER_001` için one-hot regresyon vektörü. Bu test ML teslimine bloke.

---

## Repo haritası

| Yol | Ne |
| --- | --- |
| `Kontratlar/` | ADR'ler, roadmap, kontrat değerlendirmesi, FC1 devir notu |
| `fpga/rtl/` | SystemVerilog RTL (13 modül) |
| `fpga/tb/` | Testbench'ler (10 test top) |
| `fpga/model/` | Python golden referanslar ve vektör jeneratörleri (stdlib-only) |
| `fpga/sim/run_tests.py` | XSim regression runner |
| `fpga/vivado/` | Sentez/implementation gate'leri ve proje üretme Tcl'i |
| `Rehberler/` | 8×8 systolic array çalışma kitabı (143 sayfa) + HTML rehber |
| `cnn_pipeline/` | ML tarafı: training, calibration, INT8 PTQ, golden vektörler |

### Testleri çalıştırma

```bash
cd fpga
python sim/run_tests.py            # tam regression
python sim/run_tests.py --list     # test topları
python sim/run_tests.py tb_conv1_top
```

Vivado 2025.1 gerekiyor. **Yol ASCII olmalı** — Vivado non-ASCII karakterli yolları
okuyamıyor (`?` yapıp "dosya yok" diyor); `run_tests.py` bunu açıkça kontrol ediyor.
`sim/vectors/*.mem` gitignore'lu ve deterministik olarak üretiliyor, ilk koşuda jeneratörler
kendiliğinden çalışır.

### Sentez

```bash
vivado -mode batch -source vivado/check_synth_conv1.tcl   # top conv1_top
vivado -mode batch -source vivado/check_synth_accel.tcl   # top accel_top
vivado -mode batch -source vivado/check_impl_conv1.tcl    # opt/place/route + post-route
```

---

## Vivado'da iki kere bedel ödenen ders

Simülasyonda **tamamen görünmeyen**, haftalardır yeşil olan modüllerde duran iki kusur:

1. **32-bit `integer` aritmetiği ve değişken bölme/modulo CARRY4 zinciri oluyor.**
   `window_gen` `k_count`'tan indeks üretmek için kombinasyonel 32-bit `/` ve `%`
   kullanıyordu: WNS **−33,324 ns**, 3935 failing endpoint, 6148 LUT. Sayaç + doğru bit
   genişliği ile **347 LUT**'a indi.
2. **İki boyutlu bellek dizisinde RAM inference çalışmıyor**, flip-flop + mux konisi
   kuruluyor. `weight_feeder` 524.288 register denedi (`Synth 8-11357`). `generate` içinde
   banka başına ayrı tek boyutlu dizi + senkron okuma ile **16 RAMB36** (banka başına 2).

Üçüncüsü ayrı bir sınıf: **ağırlık bankaları netlist'te hiç yoktu.** Ne write port'u ne
initialization'ı olduğu için sentez onları sabit sayıp siliyordu, ama simülasyon yeşildi
çünkü testbench hiyerarşik olarak dolduruyordu. "Sim geçiyor, donanımda ağırlık yok" sınıfı.
Bugün eklenen `tb_weight_feeder_init` tam bu sınıfı kapatıyor: hiç yükleme yapmadan,
hiyerarşik poke de kullanmadan bankaların doğru içeriğe sahip olduğunu doğruluyor.

---

## Süreç kaydı

Kararların nasıl alındığı ADR'lerin kendi "Ek madde" bölümlerinde tarihli olarak duruyor —
hangi iddianın sonradan yanlış çıktığı dahil (örn. ADR-018, ADR-016'nın FC1 one-liner'ını
kendi içinde düzeltiyor; ADR-011 `.coe` kararının preload yolunun açık kaldığını kaydediyor).
`Kontratlar/Tasarım Süreci Araştırma Log.md` ve `Kontratlar/Roadmap.md` daha geniş kronolojiyi
tutuyor.
