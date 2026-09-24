# Integer MaxPool2d ve CHW Flatten

[integer_tensor_ops_ref.py](../../integer_tensor_ops_ref.py), saf Python integer
ile iki bağımsız işlem sağlar. Conv/Linear/requantizer koduna bağımlı değildir;
PyTorch yalnız test karşılaştırmasında kullanılır.

## Kullanım

`cnn_pipeline` import yolundayken:

```python
from integer_tensor_ops_ref import integer_maxpool2d_ref, integer_flatten_chw_ref

x = [[[1, 5, 2, 4], [3, 0, 8, 6]],
     [[-9, -3, -8, -2], [-4, -7, -6, -5]]]
y = integer_maxpool2d_ref(x)       # [[[5, 8]], [[-3, -2]]]
z = integer_flatten_chw_ref(y)     # [5, 8, -3, -2]
```

İlk kanalın ilk penceresi `max(1,5,3,0)=5`, ikinci penceresi
`max(2,4,8,6)=8`. Negatif kanalın ilk penceresi `max(-9,-3,-4,-7)=-3`;
maksimum sıfırla başlatılmaz ve negatif değerler korunur.

## Matematiksel kapsam

- MaxPool: `[C,H,W] → [C,H/2,W/2]`, yalnız kernel=2, stride=2, padding=0.
  H/W çift ve en az 2 olmalı. Tek veya küçük boyutlar ValueError üretir.
  Bu bilinçli LeNet kapsamıdır; genel PyTorch MaxPool2d'nin tek boyutlardaki
  davranışını desteklediğimiz anlamına gelmez.
- Flatten: herhangi bir boş olmayan rectangular CHW girdiyi `c → h → w`
  sırasında düzleştirir; w en hızlı değişir. Tek veya 1 boyutlu uzamsal
  eksenler Flatten için geçerlidir. Transpozisyon yapılmaz.
- İki fonksiyon da iç içe built-in list/tuple ve built-in Python int bekler.
  Bool/float/scalar dönüşümü yapılmaz. Yanlış rank/tip TypeError;
  boş/ragged yapı ve [-128,127] dışındaki değer ValueError üretir.
- Girdilerin tamamı önce doğrulanır. Çıktılar yeni listelerdir; girdiler
  değiştirilmez. MaxPool yalnız değer döndürür; eşit maksimumların konumunu
  veya argmax indeksini seçen bir kontrat tanımlamaz.

Her iki işlem signed INT8 değerlerini korur. Scale, rounding, requantization,
bias veya yeni quantization uygulanmaz. Mevcut Conv/Linear çıktıları INT32
olduğundan bu fonksiyonlar onlara doğrudan bağlanmış sayılmaz.

## Scale neden korunabilir?

Aynı pencere için ortak `s > 0` ve zero-point `z` kullanılıyorsa
`real = s * (q-z)` sıralamayı korur. Dolayısıyla:

```text
max(s*(q-z)) = s*(max(q)-z)
```

Integer maksimumu seçmek yeterlidir; çıktı aynı scale/zero-point ile
 yorumlanabilir. Flatten da yalnız eleman sırasını düzenler, değerleri değiştirmez.
Bu matematiksel özellik gerçek RTL quantization sınırlarını veya
requantization–pool yerleşimini kesinleştirmez. Bunlar Kişi B ile ortaklaşa
kararlaştırılmalıdır; RTL/FPGA eşleşmesi bu testlerden çıkarılamaz.

## Doğrulama

Önce bağımsız test dosyası, ardından bütün paket çalıştırıldı:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider \
  cnn_pipeline/tests/test_integer_tensor_ops_ref.py
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

**44 bağımsız test; bütün pakette 239 passed (195 mevcut + 44 yeni).**
Pozitif/negatif çok kanallı pencereler, eşit maksimumlar, -128/127,
asimetrik CHW sırası, girdi değişmezliği, hata koşulları ve şu LeNet şekilleri
kontrol edildi:

- `[6,28,28] → [6,14,14]`
- `[16,10,10] → [16,5,5] → [400]`

Küçük signed integer örneklerde FP32 MaxPool2d ve Flatten karşılaştırması da
geçti. Bu değerler FP32'de tam temsil edilebilir; quantized backend veya genel
FP32–INT8 bit-exact iddiası değildir. Testlerin gerçek checkpoint/veri bağımlılığı yok.

Yalnız bu README, integer_tensor_ops_ref.py ve ilgili test dosyası eklendi.
Eski modüller değiştirilmedi; tam CNN kurulmadı. Bias/M0/n/scale üretimi,
gerçek inference/calibration/eğitim/accuracy, hardware export veya RTL entegrasyonu
yapılmadı. Paket kurulmadı; commit/push/PR/merge yapılmadı. Tüm paketteki mevcut
sentetik fixture testleri çalıştırıldı.
