# Bias'sız integer Linear/MAC referansı

[integer_linear_ref.py](../../integer_linear_ref.py), hazır signed INT8
`x[K]` ve `weights[out,K]` girdileriyle `y[c] = Σ x[k] * weights[c][k]`
hesaplar. Python int kullanır; checkpoint, görüntü, NumPy/PyTorch veya başka
proje modülü gerektirmez. Bias, scale, requantization ve batch desteği içermez.

## Kullanım

`cnn_pipeline` import yolundayken:

```python
from integer_linear_ref import integer_linear_ref, checked_int32

x = [2, -3, 4]
w = [[5, 6, -2], [-1, 0, 3]]
y = integer_linear_ref(x, w)  # [-16, 10]
```

Elle hesap:

- Kanal 0: `2*5 + (-3)*6 + 4*(-2) = 10-18-8 = -16`.
- Kanal 1: `2*(-1) + (-3)*0 + 4*3 = -2+0+12 = 10`.

Çıkış bir Python int listesidir; INT8'e daraltılmaz. Satır c daima çıktı kanalı
c'dir. Bu, [ADR-011](../../../Kontratlar/ADR-011%20Ağırlık%20Bellek%20Adresleme.md)
ve model.py içindeki Linear `[out,in]` sırasını korur. Transpozisyon veya bank
adreslemesi yapılmaz. Etiketsiz girdinin kullanıcının amaçladığı kanal sırası
olduğunu kod tahmin edemez; verilen satır sırasını aynen korur ve test eder.

## Girdi ve aritmetik kontratı

- x, weights ve her ağırlık satırı built-in list/tuple olmalı; boş olamaz.
- Her satır tam K eleman içermeli; ragged veya farklı boyutlar reddedilir.
- Elemanlar built-in Python int ve [-128,127] aralığında olmalı. Bool, float,
  string, NumPy scalar/tensor için sessiz dönüşüm yapılmaz.
- Bütün girdiler hesaplamadan önce doğrulanır; girdilere yazılmaz.
- Signed INT8 çarpımı [-16256,16384] aralığındadır ve INT16'ya sığar.
  Çarpma ve toplama sınırsız Python int ile exact yapılır.
- `checked_int32(value, name=...)`, [-2^31,2^31-1] temsil kontrolünü ayrıca
  sağlar. Tip hatası TypeError, boyut/INT8 aralık hatası ValueError,
  INT32 taşması OverflowError üretir.

[ADR-003](../../../Kontratlar/ADR-003%20INT8%20Fixed-Point%20Formatı.md)
INT32 accumulator'ı belirler; bu modül herhangi bir wrap/saturation uygulamaz.
Her kanalın exact son toplamı hesaplanır ve kontrol edilir. Ayrıca k=0'dan
K-1'e ilerleyen ara toplamlarda ilk taşma saklanır. Son toplam sığsa bile
ara taşma varsa kanal, k indeksi ve değer belirtilerek reddedilir.

Örnek: 131072 adet `(-128)*(-128)` terimi `2147483648` yapar; INT32 üst
sınırını bir aşar. Ardından -128 eklenirse son toplam `2147483520` ile aralığa
döner; buna rağmen ara taşma raporlanır. Sonuçlar hiçbir aşamada kırpılmaz.

**Bu ret, geçici bir yazılım kontrolüdür; nihai hardware overflow politikası
değildir.** Fiziksel RTL toplama sırası farklı olabilir. Kişi B ile ara/son
accumulator taşmasında davranış ve hata protokolü netleşmelidir. Başarılı Python
testi tek başına RTL/FPGA bit-exact eşleşmesini kanıtlamaz.

Mevcut LeNet'in bias'sız Linear katmanlarında en büyük K=400 olduğundan
`400*16384 = 6553600` kaba mutlak sınırı INT32'ye sığar. Bu gözlem bias eklenecek
gelecek aşamanın taşma güvenliğini kanıtlamaz.

## Testler

Önce bağımsız dosya, sonra bütün paket çalıştırıldı:

```bash
PYTHONDONTWRITEBYTECODE=1 python -B -m pytest -c cnn_pipeline/pytest.ini -q \
  -p no:cacheprovider cnn_pipeline/tests/test_integer_linear_ref.py
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

**Bağımsız testler: 32 passed. Tüm paket: 167 passed (135 mevcut + 32 yeni).**
Elle hesaplanan iki/çok kanallı örnekler, iptal olan terimler, signed INT8 uçları,
sıfırlar, satır sırası, bozuk boyut/tip/aralık, INT32 sınırları, gerçek pozitif
ve negatif MAC taşması, ara taşma sonrası iptal ve girdi değişmezliği kapsandı.
Testler gerçek checkpoint/dataset gerektirmez.

Yalnız bu README, integer_linear_ref.py ve test_integer_linear_ref.py eklendi.
Bias, M0/n, requant katman birleştirme, Conv, gerçek inference/calibration,
eğitim, accuracy ve export yapılmadı. Paket kurulmadı; commit/push/PR/merge yok.
Tüm paket içindeki mevcut sentetik fixture testleri çalıştı.
