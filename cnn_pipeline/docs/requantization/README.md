# INT32 → INT8 requantization referansı — T_NUM_REQ_001

[requant_ref.py](../../requant_ref.py) bağımsız, saf Python integer referansıdır.
Checkpoint, veri kümesi, NumPy, PyTorch, quantized backend veya çalışma çıktısı
istemez. Tam CNN golden reference değildir; RTL simülasyonu henüz yapılmadı.

## Kullanım ve kontrat

`cnn_pipeline` import yolundayken:

```python
from requant_ref import requant_raw, requant_ref

requant_raw(-3, 65536, 17)              # -1: saturation öncesi
requant_ref(-3, 65536, 17)              # -1: signed INT8 çıkış
requant_ref(-3, 65536, 17, relu=True)   # 0: ReLU'lu çıkış
```

Sonuç bir Python `int` değeridir; packed byte/tensor/export değildir. API:

- `requant_raw(acc, M0, n)`: doğrulanmış, yuvarlanmış saturation öncesi integer.
- `requant_ref(acc, M0, n, *, relu=False)`: raw sonucu [-128,127] veya [0,127]
  aralığına sınırlar.
- `checked_signed50(value, *, name=...)`: ara değer kontrolü; wrap/saturation yok.

acc, M0 ve n için yalnız built-in Python `int` kabul edilir; bool, float,
NumPy integer veya tensor otomatik dönüştürülmez. `relu` yalnız bool kabul eder.
Girdi tipi hataları `TypeError`, alan/aralık ve n=0 hataları `ValueError`,
50-bit taşmaları `OverflowError` üretir.

[ADR-003](../../../Kontratlar/ADR-003%20INT8%20Fixed-Point%20Formatı.md) uyarınca:

```text
acc ∈ [-2^31, 2^31-1]
M0 ∈ [2^16, 2^17)    # pozitif değer; signed 18-bit taşıyıcıya sığar
n ∈ [0,63]          # alan kontrolü; ayrıca aşağıdaki geçici sınırlamalar var
product = acc * M0
rounding = 2^(n-1)
total = product + rounding
y_raw = total >> n
y = min(127, max(0 if relu else -128, y_raw))
```

Product, rounding sabiti ve total **ayrı ayrı** signed 50-bit aralığında
`[-2^49, 2^49-1]` doğrulanır. Python'ın sınırsız integer aritmetiği taşmayı
saklamak için değil, tam değeri hesaplayıp kontrol etmek için kullanılır.
Negatif Python `>>` aşağıya yuvarlayan aritmetik kaydırmadır; signed RTL
`>>>` davranışıyla uyumludur. RTL operandları unsigned olursa bu eşleşme bozulur.

Bu çıkış clamp'i, önceki candidate float quantizer'ın [-127,127] aralığıyla
karıştırılmamalı: **ReLU'suz requant çıkışı -128'i içerir.**

## Elle hesaplanan tie örneği

acc=-3, M0=65536, n=17 için:

```text
product  = -196608
rounding =   65536
total    = -131072
raw      = -131072 >> 17 = -1
```

Ölçeklenmiş tam rasyonel değer -1,5'tir. Half-up tie'ı +∞ yönüne yuvarlar ve
-1 verir. Away-from-zero ve nearest-even aynı örnekte -2 verir. +0,5 örneğinde
half-up +1, nearest-even 0 verir. Testler bu sonuçları açık sabitlerle doğrular;
Python `round()` veya float üzerinden bir oracle kullanılmaz.

Tek M0 örneği: acc=1, M0=65537, n=1 → 32768,5 → raw=32769.
Negatif eşleniği -32768,5 → raw=-32768. Bu büyük raw sonuçlarda saturation
rounding farkını gizleyebileceği için `requant_raw` ayrıca test edilir.

## n alanı ile 50-bit genişlik uyuşmazlığı

| n | İlk referans davranışı | Gerekçe |
|---|---|---|
| 0 | Açık hata | ADR bu durumu kapatmıyor; `2^(n-1)` negatif üs/shift olur |
| 1…49 | Kabul | Bütün geçerli acc/M0 değerlerinde üç ara değer de sığar |
| 50…63 | OverflowError | Pozitif `2^(n-1)` sabiti signed 50-bit'e sığmaz |
| <0 veya >63 | Alan hatası | Unsigned 6-bit dışında |

**Bu tablo yeni nihai hardware kararı değildir.** n=0 reddi geçici sınırdır.
50…63 reddi, bu sürümde bütün ara operandlar/toplam için uygulanan katı
signed 50-bit kontrolünün sonucudur.

Güvenli bölgenin cebirsel kontrolü:

```text
minimum product = (-2^31)(2^17-1) = -2^48 + 2^31
maximum product = (2^31-1)(2^17-1) = 2^48 - 2^31 - 2^17 + 1
maximum rounding (n=49) = 2^48
maximum total = 2^49 - 2^31 - 2^17 + 1 < 2^49
```

Yuvarlama sabiti pozitif olduğundan minimum toplam minimum çarpımdan da
büyüktür; alt sınıra taşma yoktur. Dolayısıyla geçerli acc/M0 ve n=1…49 için
**toplam taşması ulaşılabilir değildir**, ancak referans toplamı yine de
kontrol eder. Testler signed50 kontrolüne sınır dışı sentetik toplamlar vererek
reddi doğrular; bunlar ulaşılabilir requant vektörleri diye sunulmaz.

n=50'de sabit `2^49` zaten maksimum pozitif signed 50-bit değerden bir büyüktür.
Negatif product ile toplam sığsa bile sabitin kendisi temsil edilemediğinden
reddedilir. n=63'te sabit `2^62` olur. Onu 50-bit'e kırpmak veya shift'i
maskelemek farklı bir algoritma üretir; bu referans ikisini de yapmaz.

RTL ekibine götürülecek kararlar:

1. n=0 yasak mı kalacak, yoksa ayrı bir matematiksel yol mu tanımlanacak?
2. n=50…63 konfigürasyonları reddedilecek mi, rounding/toplam yolu genişletilecek
   mi, yoksa kanıtlanmış eşdeğer bir işlem mi kullanılacak? Henüz seçilmedi.
3. Geçersiz konfigürasyon/taşma donanımda nasıl bildirilecek? Python exception'ının
   RTL hata protokolü karşılığı henüz yok; wrap/saturation varsayılmamalı.
4. Çarpım, sabit, toplama ve shift ifadelerinin açık signed genişlikleri aynı
   mı? Özellikle RTL'de dar/unsized `1 << (n-1)` kullanımına güvenilmemeli.

## Test kapsamı ve sonuç

[T_NUM_REQ_001 testleri](../../tests/test_requant_ref.py) şunları kapsar:

- Sıfır, pozitif/negatif acc, INT32 uçları; M0 alt/üst sınırları ve geçersiz alanlar.
- Tek/çift M0 ile kasıtlı ±tie; alternatif rounding yöntemlerinden ayrışan
  elle hesaplanmış raw ve son çıkışlar.
- -129, -128, -127, 0, 126, 127, 128 çevresinde tam değerler ve yarım adımlar;
  her iki ReLU seçeneği.
- n=1…49'un tamamında dört M0 sınır/yakın-sınır değeri ve beş acc değeri.
- n=0, 50…63'ün tamamı (n=63 dahil), operand ve 50-bit guard sınırları.
- Sabit seed=42 ile 2.000 geçerli rastgele vektör; raw ve iki saturation yolu.

Rastgele/sınır oracle'ı `fractions.Fraction` ile tam rasyonel değerin iki komşu
tamsayıya mesafesini karşılaştırır; eşitlikte büyük olanı seçer. Üretim kodunun
“rounding sabiti ekle + sağa kaydır” algoritmasını tekrar etmez. Kasıtlı tie
örnekleri doğrudan verilir; yalnız tek M0 için geçerli modüler ters üreticisi
kullanılmadı. Bütün requant test acc değerleri alan kontrolünden geçer;
geçersiz giriş testleri ayrıca ayrılmıştır.

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

**Tüm paket: 135 test geçti (74 mevcut + 61 yeni test durumu).** Parametrik test
sayısı vektör sayısı değildir; bazı testler çok sayıda vektör içerir.

Doğrulanan şey Python aritmetiğinin belirlenen geçerli bölgede bağımsız exact
beklentilerle birebir örtüşmesidir. **RTL/FPGA bit-exact eşleşmesi henüz
kanıtlanmadı.** [ADR-009](../../../Kontratlar/ADR-009%20Doğrulama%20Ortamı.md)
requantizer birim karşılaştırmasını saf RTL doğrulama katmanına yerleştirir;
sonraki çalışmada aynı vektörler RTL ile karşılaştırılmalıdır. Bu görevde
simülatör veya hardware export çalıştırılmadı.

Yalnız requant_ref.py, test_requant_ref.py ve bu README eklendi. Mevcut kod,
checkpoint/calibration/quantization çıktıları ve geçmiş raporlar değiştirilmedi.
Tüm paket içindeki mevcut sentetik fixture testleri çalıştı; gerçek model
inference, calibration veya accuracy koşusu yapılmadı. Paket kurulmadı;
commit/push/PR/merge yapılmadı.
