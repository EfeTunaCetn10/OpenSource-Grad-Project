---
title: ADR-003 INT8 Fixed-Point Formatı
created: 2026-08-28
modified: 2026-09-25
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
| Accumulator | INT32 signed; her MAC ve bias toplaması modulo `2^32` wrap, accumulator içinde saturation yok |
| Bias | INT32 signed, acc domain'inde: `bias_q = round(b_float / (s_w · s_x))`, per-channel |
| M0 (multiplier) | unsigned değer, `[2^16, 2^17)` aralığına normalize (17 anlamlı bit), **signed register'da tutulur** |
| n (shift) | unsigned 6-bit (`0..63`), per-channel |
| Requant hesap yolu | **signed 64-bit** product + rounding offset + arithmetic shift; matematiksel `INT32 × signed-18-bit M0` product 50 bit'e sığar |
| Requantization | `half_ulp = (n == 0 ? 0 : 2^(n-1))`; `y_raw = (acc·M0 + half_ulp) >>> n` |
| Rounding | **round-half-up** (eşitlikte +∞ yönüne; away-from-zero DEĞİL) |
| ReLU + saturation | `y = clamp(lo, 127, y_raw)`, `lo = 0` (ReLU'lu) / `-128` (ReLU'suz) |
| Signedness | Arithmetic operands ve intermediates `signed`; shift count `n` unsigned |

ReLU ayrı bir aşama değil, saturasyonun alt sınır parametresidir — bu, Roadmap §4.3'ün
"bias, ReLU ve pooling işlem sırası" belirsizliğini tek maddede kapatıyor.

`wrap32(v) = ((v + 2^31) mod 2^32) - 2^31`. Her output için bias ve tüm INT8 product'lar
`wrap32` altında toplanır; INT8 saturation yalnız requantization sonunda uygulanır.
`wrap32` addition associative olduğundan integer golden model MAC'leri array ile aynı sırada
toplamak zorunda değildir. Overflow oluşursa da sonuç modulo `2^32` aynı kalır.

> [!warning] `n = 0` yasal olduğu için config guard'ı `M0`'a düşüyor
> Bu ADR'nin önceki taslağında `n` aralığı `[1,49]` ile sınırlıydı ve `SHIFT` register'ının
> reset değeri `0` "parametresiz cihaz başlayamaz" garantisini bedava veriyordu. `n = 0` artık
> aritmetik olarak tanımlı ve yasal olduğundan bu garanti **kayboldu**: reset sonrası
> `M0 = 0, n = 0, bias = 0` ile cihaz sessizce `y = 0` üretir — hata değil, yanlış cevap.
> Guard bu yüzden **`M0 ∈ [2^16, 2^17)`** kontrolüne taşındı; `M0 = 0` bu aralığı ihlal ettiği
> için yapılandırılmamış cihaz yakalanır. Zorunlu commit-time kontrolü ve `ERR_CFG_M0` biti
> için bkz. [[ADR-015 Register Map ve Parametre Yükleme]].
> `n ∉ [1,49]` kontrolü korrektlik için **gerekli değildir** (tüm `n` tanımlı), yalnızca
> export-bug kanaryası olarak opsiyoneldir: `n ≥ 33` pratikte `M < 1,1e-5` demektir.

## Gerekçe

### Neden 64-bit requant hesap yolu
`M0 < 2^17` ve `|acc| <= 2^31` olduğundan `|acc·M0| < 2^48`.
6-bit `n` en çok 63 olabilir; en büyük `half_ulp = 2^62`. Toplamın mutlak değeri
`2^62 + 2^48`'den küçüktür ve signed 64-bit'e sığar. 50-bit yalnız multiplication
product'ı taşır; büyük `n` değerlerinde rounding offset'i taşımaz. 64-bit adder/shift
path'inin LUT ve timing maliyeti synthesis ile ölçülecek; DSP sayısı varsayımla
kesinleştirilmeyecek.

### Neden INT32 wrap accumulator
Aşama 1 modelinde `K_model_max = 400`. Worst-case `|INT8×INT8| <= 16384`, dolayısıyla
`K·16384 <= 6.553.600`. Bias hariç signed INT32 pozitif sınıra karşı yaklaşık `328×`
margin vardır. Tam overflow proof için exported her `bias_q` ve gerçek per-layer `K`
kontrol edilir; güvenli yeter koşul `|bias_q| + K·16384 <= 2^31-1`.
Bu proof Aşama 3 modeline kendiliğinden aktarılmaz. `wrap` donanımda doğal 32-bit
addition'dır ve reduction order'dan bağımsızdır; saturating accumulator ise associative
değildir, integer golden modelin array'in MAC sırasını taklit etmesini gerektirir.

### Neden round-half-up (Roadmap taslağındaki "nearest-even" değil)
Python'da `>>` negatif tam sayılarda taban (floor) kaydırma yapar, Verilog'da `>>>` de öyle.
Yani `n>0` için `(acc·M0 + (1 << (n-1))) >> n` ifadesi Python golden model ile RTL'de **ekstra kod
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
requant yolundaki tüm **aritmetik** sinyaller `signed`, M0 ise MSB'si daima 0 olan signed
register'da. **İstisna:** shift count `n` unsigned'dır (Verilog shift miktarını zaten daima
unsigned yorumlar) — karar tablosundaki satırla uyumlu.

### 2. DSP sayısı — 1 değil 2
DSP48E1'in çarpanı 25×18 signed. Requant çarpımı 32-bit acc × 18-bit M0 olduğu için tek slice'a
sığmaz; multiplier için 2 DSP48E1 varsayımı sentezle doğrulanacak. Tahmini bütçe:
64 (array) + 8×2 (requantizer) = **80/220, %36**. 64-bit rounding adder/shift path ayrıca
LUT ve timing etkisi yaratabilir. Acc'yi 25 bit'e saturate edip 8 DSP'ye inmek mümkün ama
**önerilmiyor**: DSP darboğaz değil, ve "pratikte hiç tetiklenmeyen" saturasyon maddeleri golden model ile RTL'in sessizce
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
- Integer golden modelde MAC ve bias için açık `wrap32`, requant için Python `int` veya
  `np.int64` kullanmak. `np.int32` implicit overflow'a güvenilmez; product + rounding
  offset tüm `n=0..63` aralığında 64-bit olmalı. Export sırasında bias dahil overflow
  bound'u kontrol edilir

**Kişi B:**
- Tüm requant hesap yolunda `signed` bildirimler; product + offset + shift 64-bit
- PE accumulator'da 32-bit wrap; saturation yalnız requant output'unda
- `>>>` kullanmak, asla `>>`
- 8 requantizer × yaklaşık 2 DSP48E1 multiplier tahmini; synthesis ile doğrulanır
- 8 girişlik `(M0, n, bias_q)` register dosyası, tile başına yeniden yüklenir

## İlk yazılacak test — `T_NUM_REQ_001`

Requantizer'ın tek başına bit-exact testi, array'den önce. **Rounding kuralını ayırt etmek
için `pre-clamp y_raw` üzerinde tie vector kullanılır**: rastgele test bir tie'ı neredeyse
hiç vurmaz (200.000 rastgele vektörde **0** tie ölçüldü). Mevcut normalized M0 aralığında
tie vector'lerin final INT8 sonuçları saturation ile maskelenir; yalnız output'u kontrol eden
test yanlış rounding kuralıyla da geçebilir.

```python
# n > 0 için; n == 0 durumunda tie yok
# M0 tek sayi olmali (tersi alinabilsin diye)
inv  = pow(M0, -1, 2**n)
base = (2**(n-1) * inv) % 2**n                   # acc*M0 mod 2^n == 2^(n-1) veren taban
ties = [acc for j in range(-50, 51)
        if -(2**31) <= (acc := base + j*2**n) < 2**31]

vectors = ([0, 1, -1, 2**31-1, -2**31]
           + ties
           + [acc for t in (-129,-128,-127,126,127,128) for d in (0,1)
              if -(2**31) <= (acc := (t*2**n)//M0 + d) < 2**31]
           + [random.randint(-2**23, 2**23) for _ in range(10000)])
```

> [!warning] Üretecin doğru hâli
> `2**n` katı çarpımın **içine** konursa (`(2**(n-1) + j*2**n) * inv % 2**n`) `j` terimi mod
> alınırken yok olur ve üreteç 101 farklı tie yerine **aynı değeri 101 kez** verir. Bu oturumda
> çalıştırılarak doğrulandı; yukarıdaki doğru üreteç hem pozitif hem negatif acc'yi kapsıyor ve
> `pre-clamp y_raw` seviyesinde half-up ile nearest-even ayrışıyor.

Bu ayrışma normalized M0 aralığındaki tie vector'lerin tamamında INT8 saturation ile
maskelenir. `T_NUM_REQ_001`, RTL'in **pre-clamp
`y_raw`** değerini de Python reference ile karşılaştırır; yalnız final INT8 output'u
karşılaştırmak rounding kuralını doğrulamaz. `n=0` için tie yoktur. `n=31` gibi geniş
shift'lerde `INT32` dışına çıkan tie vector'ler elenir.

### Ölçülen tie kapsamı ve iki zorunlu test kuralı

Üretecin ayırt etme gücü `n`'e sert biçimde bağlı. 10 farklı `(n, M0)` çiftinde ölçüldü
(`M0` tek sayı, normalize aralıktan rastgele):

| `n` | tie sayısı | half-up ≠ nearest-even (**pre-clamp `y_raw`**) | half-up ≠ nearest-even (**final INT8**) |
|---:|---:|---:|---:|
| 1 | 101 | 50 | **0** |
| 8 | 101 | 51 | **0** |
| 16 | 101 | 50 | **0** |
| 24 | 101 | 51 | **0** |
| 31 | 2 | 1 | **0** |
| 32 | 1 | 1 | **0** |
| 33–63 | 0 | 0 | 0 |

Son sütun on vakanın **onunda da sıfır**: yalnız final INT8'i karşılaştıran bir test yanlış
rounding kuralıyla da geçerdi. Sebebi ardışık tie'lar arasında `Δy_raw = M0 ≥ 2^16` olması —
101 tie'ın en fazla biri INT8 aralığına düşer. Bu, `pre-clamp y_raw` karşılaştırmasının
tercih değil **zorunluluk** olduğunun ölçülmüş kanıtıdır.

**Kural 1 — boş tie listesi sessizce geçmemeli.** `n ≥ 33`'te tie'lar `2^n` aralıklı,
INT32 penceresi `2^32` geniş; `2^n > 2^32` olunca pencereye hiç temsilci düşmez. Üreteç boş
liste döndürür ve test "geçer".

```python
assert ties or n > 32, f"n={n}: tie üretilemedi, rounding kuralı doğrulanmıyor"
```

**Kural 2 — `n` süpürülmeli, tek değerde koşulmamalı.** Önerilen set:
`n ∈ {0, 1, 16, 20, 24, 27, 31, 32}` — pratik bandı ve iki uç davranışı (`n=0` tie yok,
`n=32` tek tie) birlikte kapsar.

> [!note] `n ≥ 33` kör noktası erişilemez, kapsama kaybı yok
> `M = M0·2^-n` olduğundan `n = 33`, `M ≈ 1,1e-5` demektir. Gerçek bir katmanda
> `M ≈ 0,001–0,05`, yani `n ≈ 20–27` — tablonun en güçlü satırları. Kör nokta ulaşılabilir
> `M` bandının tamamen dışında; bu not, sonradan keşfedilip kapsama açığı sanılmasın diye
> yazıldı.

**RTL sonucu:** test `y_raw`'ı görmek zorunda olduğundan requantizer modülü bunu port olarak
dışarı vermeli — bkz. [[ADR-014 Requantizer Port ve Zamanlama Sözleşmesi]] `out_y_raw`.

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
