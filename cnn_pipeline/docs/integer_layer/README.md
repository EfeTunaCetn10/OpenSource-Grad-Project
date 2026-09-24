# Tek katman candidate software composition

`integer_layer_ref.py` iki bağımsız fonksiyon sunar:

- `integer_linear_layer_ref(x, weights, bias_q, M0, n, *, relu)` → [C_out]
- `integer_conv2d_layer_ref(x, weights, bias_q, M0, n, *, relu, layer='conv2d')`
  → [C_out,H_out,W_out]

Bu, nihai RTL overflow politikası veya FPGA bit-exact kanıtı değildir.

## İşlem ve arayüz

MAC, mevcut `integer_linear_ref` veya `integer_conv2d_ref` üzerinden hesaplanır.
Her kanal/konum için `checked_int32(mac + bias_q[c])` uygulanır; ardından mevcut
`requant_ref(acc,M0[c],n[c],relu=relu)` çağrılır. MAC ve requant matematiği
kopyalanmadı. Conv kapsamı mevcut primitive gibi CHW, batch yok, cross-correlation,
stride=1, padding=0, dilation=1'dir.

bias_q/M0/n hazır, çıkış kanalı sırasındaki built-in int list/tuple değerleridir.
Kanal uzunluğu, tip, INT32 bias ve requant parametreleri MAC öncesinde doğrulanır.
Bool/float kabul edilmez; relu yalnız built-in bool olabilir. M0 [65536,131071],
n=0 geçici olarak reddedilir; n=50…63 mevcut signed 50-bit sabit kontrolünden
OverflowError alır. Geçersiz unsigned 6-bit değerler de reddedilir.

Girdi/weight INT8 shape/tip doğrulaması mevcut MAC primitive'ine bırakılır.
Sonuçlar yeni listelerde built-in Python int olarak döner; girdiler değişmez.
Bir hata tüm çağrıyı sonlandırır, kısmi çıktı dönmez. MAC+bias taşması katman,
kanal ve konumla raporlanır. Linear konumu scalar olarak belirtilir. Primitive
MAC taşması kendi açıklamasıyla aktarılır. Wrap veya INT32 saturation yoktur;
requant'ın nihai INT8 clamp'i korunur: ReLU ile [0,127], aksi halde [-128,127].

## Elle hesaplama

Linear x=[2,-3,4], weights=[[5,6,-2],[-1,0,3],[1,0,0]]:

| Kanal | MAC | Bias | acc | M0 / 2^n | INT8 sonuç |
| --- | --- | --- | --- | --- | --- |
| 0 | -16 | 1 | -15 | 65536 / 2^17 = 0.5 | -7 |
| 1 | 10 | -7 | 3 | 98304 / 2^17 = 0.75 | 2 |
| 2 | 2 | -6 | -4 | 65536 / 2^18 = 0.25 | -1 |

İlk kanalda -7.5 tie +∞ yönüne -7 olur. ReLU açık olduğunda sonuç [0,2,0].
Taşma örnekleri: MAC=1 ve bias=2147483647 toplamı 2147483648;
MAC=-1 ve bias=-2147483648 toplamı -2147483649. Operandlar ayrı ayrı geçerli
olmasına rağmen iki toplam da OverflowError ile reddedilir. Bu davranış
diagnostic yazılım sınırıdır; fiziksel RTL overflow davranışını kesinleştirmez.

## Kapsam ve testler

79 bağımsız sentetik test: elle hesaplanan çok kanallı Linear ve çok konumlu
Conv, farklı bias/M0/n, signed logits, ReLU, pozitif/negatif tie, INT8 saturation,
her iki yönde MAC+bias taşması, gerçek büyük sentetik Linear MAC taşmasının
aktarılması, MAC öncesi parametre reddi, shape/tip ve girdi değişmezliği.
Önemli beklentiler sabittir; primitive adımlarıyla tutarlılık ayrıca kontrol edilir.

Bias quantization ve candidate M0/n seçimi bu fonksiyonlarda yapılmaz; sonraki
model hazırlama aşamasına aittir. Tam CNN, Pool/Flatten, gerçek checkpoint/qparams
çalıştırma, calibration, accuracy veya export yoktur. Bias rounding, multiplier
seçimi ve RTL overflow kararları değiştirilmedi; mevcut primitive dosyalarına
yazılmadı. Paket kurulmadı, Git yazma işlemi yapılmadı.
