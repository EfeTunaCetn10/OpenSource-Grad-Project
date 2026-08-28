---
title: ADR-003 INT8 Fixed-Point Formatı
created: 2026-08-28
modified: 2026-08-28
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, quantization, rtl, ml]
---

# ADR-003: INT8 Fixed-Point Format Kontratı

## Durum
Kabul edildi — 2026-08-28

## Bağlam
Üç kritik kontrattan **birincisi** ve en riskli olanı: Kişi A'nın quantization'ı ile Kişi B'nin
PE aritmetiğinin bit-exact örtüşmesi. Roadmap'e göre Hafta 2'de kilitlenmeliydi; gecikme
bilinçliydi (know-how artırma). [[ADR-004 Systolic Array Boyutu|ADR-004]] (8×8) ve
[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]] (8 banka, c_out mod 8) üzerine oturuyor —
requantizer register dosyası aynı 8'li indekslemeyi kullanıyor.

## Karar

| Alan | Karar |
|---|---|
| Ağırlık | INT8 signed, simetrik (z=0), **per-output-channel** scale |
| Aktivasyon | INT8 signed, simetrik (z=0), per-tensor scale |
| Product | INT16 signed (exact) |
| Accumulator | INT32 signed |
| Bias | INT32 signed, acc domain'inde: `bias_q = round(b_float / (s_w · s_x))`, per-channel |
| M0 (multiplier) | unsigned değer, `[2^16, 2^17)` aralığına normalize (17 anlamlı bit), **signed register'da tutulur** |
| n (shift) | unsigned 6-bit, per-channel |
| Ara çarpım | **signed 50-bit** (32-bit acc × 18-bit M0) |
| Requantization | `y_raw = (acc·M0 + (1 << (n-1))) >>> n` |
| Rounding | **round-half-up** (eşitlikte +∞ yönüne; away-from-zero DEĞİL) |
| ReLU + saturation | `y = clamp(lo, 127, y_raw)`, `lo = 0` (ReLU'lu) / `-128` (ReLU'suz) |
| Signedness | Requant yolundaki **tüm** Verilog sinyalleri `signed` bildirilecek |

ReLU ayrı bir aşama değil, saturasyonun alt sınır parametresidir — bu, Roadmap §4.3'ün
"bias, ReLU ve pooling işlem sırası" belirsizliğini tek maddede kapatıyor.

## Gerekçe

### Neden round-half-up (Roadmap taslağındaki "nearest-even" değil)
Python'da `>>` negatif tam sayılarda taban (floor) kaydırma yapar, Verilog'da `>>>` de öyle.
Yani `(acc·M0 + (1 << (n-1))) >> n` ifadesi Python golden model ile RTL'de **ekstra kod
olmadan birebir aynı** sonucu verir. Oturumda doğrulandı: `-5 >> 1 == -3`, `-8 >> 2 == -2`.
Nearest-even ise RTL'de tie durumunda LSB parity kontrolü gerektirir — daha fazla mantık,
daha fazla ayrışma yüzeyi.

### Neden keyfi scale (multiplier + shift), Q1.7 değil
Huynh'un PYNQ-Z2 makalesi Q1.7 (power-of-2 scale, çarpansız, sadece kaydırma) kullanıp MNIST'te
doğruluk kaybı raporlamıyor. Ama bu "MNIST kaba quantization'a dayanıklı" kanıtıdır, "Q1.7 daha
iyi mühendislik" kanıtı değil. Q1.7 seçmek Kişi A'yı PyTorch PTQ'nun standart çıktısı olmayan
power-of-2 scale'e zorlar → özel kod, plandaki tutorial yolundan sapma. Kazanç 16 DSP (bol olan
kaynak), maliyet Kişi A'nın zamanı (kıt olan kaynak). Takas net.

### Neden simetrik — ve gerekçenin doğrusu
Yaygın gerekçe ("asimetrik pahalıdır") yalnızca **ağırlık** için doğru. Asimetrik *aktivasyon*
donanımda pratikte bedava: `acc = Σ(x_q − z_x)·w_q = Σx_q·w_q − z_x·Σw_q` ve `z_x·Σw_q` terimi
tamamen offline hesaplanıp bias'a katlanır. Bu yüzden Aşama 1'de simetrik kalıyoruz (basitlik,
ve Huynh'un emsali bu sınıfta yeterli olduğunu gösteriyor), ama **kaçış kapısı yazılı**:
aktivasyon asimetriye geçerse yalnızca export script'i değişir, RTL değişmez.

Bedeli: ReLU sonrası aktivasyonlar ≥0 olduğu için signed int8'in negatif yarısı boşa gider
(~1 bit çözünürlük). LeNet-5 + kolay dataset bunu absorbe eder.

### Neden per-channel, Aşama 1'den itibaren
PyTorch'un önerdiği ağırlık observer'ı zaten `per_channel_symmetric`; per-tensor'a düşürmek
Kişi A'ya *fazladan* iş ve doğruluk kaybı demek. Donanım maliyeti 8 girişlik register dosyası —
[[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]'in 8 bankasıyla aynı indeksleme, pratikte bedava.

## Tuzaklar — sözleşme maddesi olmalarının sebebi

### 1. Verilog signedness tuzağı (en tehlikelisi)
Verilog'da bir ifadedeki **herhangi** bir operand unsigned ise ifadenin tamamı unsigned olur ve
`>>>` mantıksal kaydırmaya döner — negatif acc'de sonuç çöp çıkar. Yani **Python varsayılan
olarak doğru, Verilog varsayılan olarak yanlış.** Bu asimetri tam olarak bu yüzden madde:
requant yolundaki tüm sinyaller `signed`, M0 ise MSB'si daima 0 olan signed register'da.

### 2. DSP sayısı — 1 değil 2
DSP48E1'in çarpanı 25×18 signed. Requant çarpımı 32-bit acc × 18-bit M0 olduğu için tek slice'a
sığmaz, Vivado 2 DSP48E1'e böler. Gerçek bütçe: 64 (array) + 8×2 (requantizer) = **80/220,
%36**. Acc'yi 25 bit'e saturate edip 8 DSP'ye inmek mümkün ama **önerilmiyor**: DSP darboğaz
değil, ve "pratikte hiç tetiklenmeyen" saturasyon maddeleri golden model ile RTL'in sessizce
ayrıştığı tam olarak o maddelerdir.

### 3. FBGEMM qint8 aktivasyonu kabul etmiyor
PyTorch'un FBGEMM backend'i quint8 (asimetrik) aktivasyon dayatıyor;
`RuntimeError: Expected activation data type QUInt8 but got QInt8` bilinen bir duvar. Sonuç:
**Kişi A PyTorch'un quantized runtime'ına bel bağlamamalı** — observer'ları yalnızca kalibrasyon
için (scale çıkarmak) kullanıp integer golden modeli NumPy'da elle yazmalı. Roadmap §4.3 bunu
zaten zorunlu kılıyor, kaybedilen bir şey yok; bu madde sadece backend'le boğuşarak hafta
harcamayı önlüyor.

### 4. Bit-exact'in kapsamı
**PyTorch quantized model ile integer golden model bit-exact OLMAYACAK** (farklı requant ve
rounding). Roadmap §4.4'teki "Quantized model ↔ Integer golden" karşılaştırması **tolerans
tabanlı** olmalı. Bit-exact sözleşme yalnızca şu zincirde geçerli:
**integer golden ↔ RTL ↔ FPGA**. Bu netleşmezse Hafta 8'de sahte bir hata avı başlar.

## Sorumluluklar

**Kişi A:**
- Kalibrasyon: `per_channel_symmetric` (ağırlık), `per_tensor_symmetric` (aktivasyon), `dtype=qint8`
- float → `(M0, n)` tamsayı dönüşümü **onun script'inde** — RTL yalnızca tamsayı alır
- Integer golden modeli **Python `int` veya `np.int64` ile** yazmak. `np.int32` aritmetiği
  taşmada sessizce sarar, `acc*M0` tam orada patlar

**Kişi B:**
- Tüm requant yolunda `signed` bildirimler; ara çarpım 50-bit
- `>>>` kullanmak, asla `>>`
- 8 requantizer × 2 DSP48E1
- 8 girişlik `(M0, n, bias_q)` register dosyası, tile başına yeniden yüklenir

## İlk yazılacak test — `T_NUM_REQ_001`

Requantizer'ın tek başına bit-exact testi, array'den önce. **Testin özü rastgele vektörler
değil, kasıtlı eşitlik (tie) vektörleridir**: rastgele test bir tie'ı asla vurmaz (bu oturumda
ölçüldü — 200.000 rastgele vektörde **0** tie), ve tie yoksa round-half-up / nearest-even /
away-from-zero **üçü de geçer**. Hata Hafta 8'de birkaç piksellik sapma olarak ortaya çıkar.

```python
# M0 tek sayi olmali (tersi alinabilsin diye)
inv  = pow(M0, -1, 2**n)
base = (2**(n-1) * inv) % 2**n                   # acc*M0 mod 2^n == 2^(n-1) veren taban
ties = [base + j*2**n for j in range(-50, 51)]   # 2^n katlarini acc'ye EKLE

vectors = ([0, 1, -1, 2**31-1, -2**31]
           + ties
           + [(t*2**n)//M0 + d for t in (-129,-128,-127,126,127,128) for d in (0,1)]
           + [random.randint(-2**23, 2**23) for _ in range(10000)])
```

> [!warning] Üretecin doğru hâli
> `2**n` katı çarpımın **içine** konursa (`(2**(n-1) + j*2**n) * inv % 2**n`) `j` terimi mod
> alınırken yok olur ve üreteç 101 farklı tie yerine **aynı değeri 101 kez** verir. Bu oturumda
> çalıştırılarak doğrulandı; yukarıdaki doğru üreteç hem pozitif hem negatif acc'yi kapsıyor ve
> tie'ların bir kısmında half-up ile nearest-even ayrışıyor — testin ayırt edici olduğunun
> kanıtı budur.

Bu test **bu hafta** yazılabilir: Kişi A `requant_ref()`'i, Kişi B RTL modülünü yazar, cocotb
ikisini birleştirir. Array henüz yokken sözleşmenin en zor maddesini kanıtlar.

## Kaynaklar
- [DSP48E1 — UG953](https://docs.amd.com/r/en-US/ug953-vivado-7series-libraries/DSP48E1)
- [torch.quantize_per_channel](https://docs.pytorch.org/docs/stable/generated/torch.quantize_per_channel.html)
- [Practical Quantization in PyTorch](https://pytorch.org/blog/quantization-in-practice/)
- [FBGEMM qint8 activation RuntimeError](https://discuss.pytorch.org/t/runtimeerror-quantized-conv-fbgemm-expected-activation-data-type-quint8-but-got-qint8/175031)
- [pytorch#76298 — qint8 activation support](https://github.com/pytorch/pytorch/issues/76298)
- [tensorflow#25087 — TFLite double-rounding](https://github.com/tensorflow/tensorflow/issues/25087)
- `Kaynaklar/IJCDS-110136-1570680228.pdf` (Huynh — Q1.7 emsali)
