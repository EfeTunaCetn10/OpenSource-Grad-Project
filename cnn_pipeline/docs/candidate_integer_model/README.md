# Bellek içi aday integer LeNet parametreleri

Bu modül yalnız **candidate software parameters** hazırlar; forward, MAC,
giriş görüntüsü veya hardware export üretmez. Bias rounding ve M0/n seçimi
mevcut aday fonksiyonlara aittir, yeni politika eklenmez.

## İki ayrı arayüz

`prepare_candidate_integer_model(qparams, model_state, weights_int8)` dosyasız
hazırlama fonksiyonudur. Saf sentetik fixture ile çalışır; provenance doğrulaması
iddia etmez. Sabit RGB/10 sınıflı LeNet bekler. Testler gerçek LeNet boyutlarında
küçük sentetik tensorler kullanır; farklı küçük ağ sessizce kabul edilmez.

`load_candidate_integer_model(qparams_path)` gerçek kullanım girişidir.
Önce mevcut `multiplier_analysis.verify_qparams` çağrılır. Checkpoint, calibration,
statistics ve weight artifact kimlik kontrolü gevşetilmez. Artifact kaydı yoksa
veya kaynak dosya eksikse durur. Yalnız kayıttaki path/hash ile eşleşen checkpoint
ve ağırlık dosyası `torch.load(map_location='cpu', weights_only=True)` ile yüklenir.
Yükleme/hazırlama sonrasında kaynak hash'leri yeniden kontrol edilir.

```python
from candidate_integer_model import load_candidate_integer_model
candidate = load_candidate_integer_model(
    'cnn_pipeline/outputs/quantization/seed42_epoch51_candidate_run01/qparams.json')
# Yalnız parametre erişimi; katman veya model çalıştırılmaz.
conv1 = candidate['layers']['features.0']
```

## Bütünlük ve bellek düzeni

Katman/input/output eşlemesi yalnız `multiplier_analysis.LAYERS` üzerinden gelir.
`analyze_qparams` mevcut policy, zero-point, scale ve shape kontrollerini yapar.
`model.py` LeNet5(3,10) meta cihazında oluşturularak weight shape ve ReLU bilgisi
çapraz kontrol edilir; gerçek parametre depolaması ve forward yapılmaz.

State dict tam beş weight ve beş bias, INT8 artifact tam beş weight içermelidir.
FP32 weight/bias ve INT8 weight dtype, boyut, sonluluk, contiguous CPU native
sıra doğrulanır. Eksik/fazla anahtar, reshape/transpose ihtiyacı reddedilir.
Mevcut `quantize_int8` ile checkpoint ağırlıkları yeniden hesaplanıp artifact ile
eleman eleman karşılaştırılır; kanal permütasyonu böylece yakalanır. Ağırlıkları
birbirinden ayırt edilemeyen eşit kanallar için fiziksel permütasyon iddiası yoktur.

Her katman paketi: `weights` (INT8 tensor), `bias_fp32` (FP32 tensor),
`weights_list`, `bias_q`, `M0`, `n`, `s_x`, `s_y`, `s_w`, `input_key`, `output_key`,
`relu`, `requant_diagnostic` ve candidate `role` içerir. Bias_q INT32 aralığı
kontrollü built-in int listesi, M0/n kanal sıralı built-in int listeleridir.
Tensorler kopyalanır; .tolist yalnız doğrulanan tensorlere uygulanır. Kaynaklar
ve rastgele sayı üreteci değiştirilmez. Başarısızlıkta kısmi paket dönmez.

ADR-011 native [out,in,kH,kW]/[out,K] sırası korunur; banka dağılımı/export yoktur.

## Gerçek artifact smoke kontrolü

Yerel doğrulanmış qparams/checkpoint/candidate_weights_int8.pt ile hazırlık
başarılı: **5 katman, 236 output channel**. Her katmanda bias_fp32, bias_q, M0 ve
n uzunlukları aşağıdaki kanal sayısıyla aynıdır:

| Katman | INT8 weight shape | Bias / M0 / n | ReLU |
| --- | --- | --- | --- |
| features.0 | [6,3,5,5] | [6] / [6] / [6] | True |
| features.3 | [16,6,5,5] | [16] / [16] / [16] | True |
| classifier.1 | [120,400] | [120] / [120] / [120] | True |
| classifier.3 | [84,120] | [84] / [84] / [84] | True |
| classifier.5 | [10,84] | [10] / [10] / [10] | False |

Bu kontrol inference/accuracy veya FPGA bit-exact kanıtı değildir. Dosya çıktısı
üretilmedi; paket yalnız bellekte tutuldu.

## Testler ve açık kararlar

Sentetik testler kanal bazında s_w=.5/.25 ve bias=1 için bias_q=2/4,
M0=65536/65536, n=17/18 beklentilerini bağımsız doğrular. Native shape, kanal
sırası, FC3 ReLU=False, değişmeyen girdiler, tekrarlanabilirlik, dtype/anahtar/
scale hataları ve sentetik dosyalarda gerçek hash/provenance reddi kapsanır.

Bias rounding ve M0/n politikaları adaydır. Gerçek quantization sınırları,
MAC+bias overflow ve n=0/50…63 RTL kararları açık kalır. Tam CNN, calibration,
training, accuracy, .coe/.bin, AXI/DMA veya RTL entegrasyonu yapılmadı.
