# Bias'sız integer Conv2d matematiksel referansı

[integer_conv2d_ref.py](../../integer_conv2d_ref.py) hazır signed INT8 değerlerle
**cross-correlation** hesaplar. Kernel ters çevrilmez. Yalnız stride=1,
padding=0, dilation=1; batch ve groups seçeneği yoktur.

- Input: `[C_in,H,W]` (CHW).
- Weight: `[C_out,C_in,kH,kW]`, native sıra.
- Output: `[C_out,H-kH+1,W-kW+1]`, iç içe listelerde Python int toplamları.

```text
acc[co,h,w] = Σ_ci Σ_kh Σ_kw x[ci,h+kh,w+kw] * weight[co,ci,kh,kw]
```

Doğrudan kayan pencere kullanılır. im2col matrisi, DDR export'u, line-buffer
veya fiziksel RTL zamanlaması modellenmez. İndirgeme `ci → kh → kw`
sırasındadır; ADR-011 adresleme sırasıyla uyumludur, fiziksel MAC sırası iddiası
 değildir. Bias, requantization veya diğer ağ işlemleri yoktur.

## Kullanım ve elle hesap

`cnn_pipeline` import yolundayken:

```python
from integer_conv2d_ref import integer_conv2d_ref

x = [[[1, 2, 3], [4, 5, 6], [7, 8, 9]]]
w = [[[[1, 2], [3, 4]]]]
y = integer_conv2d_ref(x, w, layer="example")
# [[[37, 47], [67, 77]]]
```

Sol üst değer `1*1 + 2*2 + 4*3 + 5*4 = 37`.
Kernel iki eksende çevrilseydi 23 çıkardı; asimetrik test bu hatayı yakalar.
Satır ve sütun tek başına çevirme de farklı sonuç verir.

## Doğrulama ve taşma

Tensorler rectangular, boş olmayan built-in list/tuple olmalı. Scalar elemanlar
built-in Python int ve [-128,127] olmalı; bool/float/NumPy scalar/tensor için
otomatik dönüşüm yapılmaz. Candidate quantizer'ın [-127,127] alt kümesi de
geçerlidir. Yanlış rank/tip `TypeError`; boş/ragged yapı, kanal uyuşmazlığı,
büyük kernel veya INT8 dışı değer `ValueError` üretir. Bütün girdiler önce
kontrol edilir; değiştirilmez. Çıktı kanalları ağırlıkların verilen sırasındadır.

Hesap Python int ile exact yapılır. Linear referansındaki `checked_int32`
yeniden kullanılır; her ara toplam ve son toplam [-2^31,2^31-1] içinde
kontrol edilir. İlk taşmada `OverflowError` katman adını, çıktı kanalını,
(h,w) konumunu ve (ci,kh,kw) indeksini bildirir. Çıktı kısmen döndürülmez;
wrap/saturation yoktur. İlk ara taşmada durulduğundan sonraki terimlerin
olası iptali bu kontrolü geçersiz kılmaz.

Bu **geçici yazılım reddidir**; RTL'nin toplama sırası, ara taşma davranışı ve
hata protokolü Kişi B ile ayrıca kapatılmalıdır. RTL/FPGA bit-exact doğrulaması
yapılmadı.

Mevcut model.py için bias hariç kaba mutlak sınırlar:

| Katman | İndirgeme uzunluğu | En büyük mutlak toplam sınırı |
|---|---:|---:|
| Conv1 | 3×5×5 = 75 | 75×16384 = 1.228.800 |
| Conv2 | 6×5×5 = 150 | 150×16384 = 2.457.600 |

Her ikisi ve ara toplamları INT32'ye sığar. Taşma testi bu şekillerde taşma
olduğunu iddia etmez: LeNet dışı `[1,1,131072]` input ve aynı genişlikte kernel
ile 131072 adet `(-128)*(-128)` toplamı 2^31'e ulaşır. Ayrı sınır testleri
INT32 alt/üst uçlarının kabulünü ve bir dışındaki değerlerin reddini doğrular.

## Test sonuçları

Önce bağımsız dosya, ardından tüm paket:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider \
  cnn_pipeline/tests/test_integer_conv2d_ref.py
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

**28 bağımsız test; tüm pakette 195 passed (167 mevcut + 28 yeni).**
Elle hesap, asimetrik/rectangular kernel, çok giriş/çıkış kanalı, signed uçlar,
iptal olan terimler, sıfırlar, yanlış yapılar/tip/aralık, girdi değişmezliği ve
taşma mesajı kapsandı. Conv1 `[3,32,32]×[6,3,5,5]→[6,28,28]` ve Conv2
`[6,14,14]×[16,6,5,5]→[16,10,10]` için shape yanında sabit girdilerin
bilinen çıktı değerleri de kontrol edildi.

Küçük sentetik integer girdiler ayrıca `torch.nn.functional.conv2d` FP32
sonucuyla karşılaştırıldı. O örnekte çarpımlar ve bütün toplamlar FP32'de tam
temsil edilebilir; bu, genel FP32–INT8 bit-exact iddiası veya quantized backend
karşılaştırması değildir. Üretim çekirdeği PyTorch import etmez.

Yalnız integer_conv2d_ref.py, tests/test_integer_conv2d_ref.py ve bu README
eklendi. Gerçek checkpoint inference/calibration, eğitim, accuracy, bias,
M0/n, requant bağlantısı, ReLU/Pool/Flatten ve hardware export yapılmadı.
Paket kurulmadı; commit/push/PR/merge yok. Tüm paketin mevcut sentetik
fixture testleri çalıştırıldı.
