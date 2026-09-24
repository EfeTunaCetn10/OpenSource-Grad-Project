# Aday bias quantization referansı

`bias_quant_ref.py`, bağımsız `quantize_bias_candidate(bias, activation_scale,
weight_scales)` fonksiyonunu sunar. Gerçek checkpoint, dataset veya RTL gerekmez.
Mevcut quantization modülündeki `round_half_up` yardımcısını kullanır; PyTorch
quantized runtime kullanmaz.

## Matematik ve aday politika

ADR-003 bias için signed INT32 ve accumulator ölçeğini tanımlar:

`bias_q[c] = round_half_up(bias[c] / (s_x * s_w[c]))`

`s_x` tek aktivasyon ölçeği, `s_w[c]` çıkış kanalına ait ağırlık ölçeğidir.
Bu sürümde float→integer bias dönüşümünün half-up olması **deneysel adaydır**.
Tie +∞ yönüne gider; requantizer'ın kabul edilmiş rounding kuralı bias için
kendiliğinden bir ADR kararı oluşturmaz.

Örnek: `s_x=0.5`, `s_w=[0.25,0.25]`, `bias=[0.3125,-0.3125]`.
Accumulator ölçekleri `[0.125,0.125]`, oranlar `[2.5,-2.5]`, sonuç `[3,-2]`.
Negatif tie sıfırdan uzağa yuvarlanmaz.

## Arayüz ve hata davranışı

Bias ve weight scale, boş olmayan 1-D float32/float64 tensor veya Python float
listesi/tuple'ı olabilir. Activation scale Python float veya sıfır boyutlu
float32/float64 tensor olmalıdır. Bool, integer ve complex girdiler dönüştürülmez.
FP32 checkpoint bias tensorü CPU float64'e tam olarak yükseltilir; Python float
ve float64 girdiler önce float32'e daraltılmaz. Çarpım, bölme ve rounding CPU
float64 kullanır. Gerçek sayı aritmetiğinin sınırsız hassasiyetli sonucu iddia edilmez.

Çıktı kanal sırası korunmuş yeni bir CPU `torch.int32` tensorüdür. Girdilere yazılmaz.
Shape/kanal uyuşmazlığı, NaN/Inf, sıfır/negatif scale, scale çarpımında
underflow/overflow ve sonlu olmayan oran reddedilir. Yuvarlanmış değer INT32
aralığı dışında ise kanal indeksli `OverflowError` oluşur; cast öncesi kontrol
edilir, wrap/saturation uygulanmaz. Bias'ın sıfır olması geçerlidir, sıfır scale
ise geçerli değildir ve fallback atanmaz.

## Gerçek qparam noktalarına dayalı ayrı aday eşleme

Kaynak: `cnn_pipeline/outputs/quantization/seed42_epoch51_candidate_run01/qparams.json`.
Bu kayıttaki seed=42, epoch=51 checkpoint:
`cnn_pipeline/outputs/resize_cosine_60epochs/insects/best.pt`.
Kayıtlı SHA256: `9983f9d32e755f2821337a8e0c6c144a71069fd36e2da8b5235840251af1947e`.
Aşağıdaki tablo qparam kaydı ve `model.py` topolojisine dayanır; nihai RTL
quantization sınırları onaylanmadan hardware kontratı değildir.

| Katman / bias anahtarı | s_x aktivasyon anahtarı | s_x adayı | s_w anahtarı / kanal sayısı |
| --- | --- | --- | --- |
| Conv1 / features.0.bias | input (normalize edilmiş) | 0.0306659120274341 | features.0 / 6 |
| Conv2 / features.3.bias | features.1 (Conv1 ReLU → Pool) | 0.03986318092646561 | features.3 / 16 |
| FC1 / classifier.1.bias | features.4 (Conv2 ReLU → Pool → Flatten) | 0.0700418817715382 | classifier.1 / 120 |
| FC2 / classifier.3.bias | classifier.2 (FC1 ReLU) | 0.13830929853784757 | classifier.3 / 84 |
| FC3 / classifier.5.bias | classifier.4 (FC2 ReLU) | 0.15940790852223793 | classifier.5 / 10 |

Kullanımda `activation_qparams[anahtar].scale` ve
`weight_qparams[katman].scale` alınmalıdır; tablodaki ondalık sayılar elle koda
kopyalanmamalıdır. Bias checkpoint'in `model_state` kaydından alınır. Entegrasyonda
checkpoint SHA256 ve qparam provenance doğrulanmalı, bias uzunluğu ile axis=0
weight scale sayısı eşleştirilmelidir. Bağımsız fonksiyon bu dosyaları yüklemez.

Pool aynı pozitif scale/zero-point ile sıralamayı korur; Flatten değerleri yalnız
yeniden sıralamadan düzleştirir. Bu nedenle scale taşıma bu aday eşlemeyi mümkün
kılar. FC3 bias'ı için final logits ölçeği değil FC2 ReLU ölçeği kullanılır.

## Test kapsamı ve açık kararlar

Sentetik testler elle hesaplanmış kanal sonuçlarını, signed tie ve tie komşularını,
INT32 uçlarını, cast öncesi overflow reddini, hatalı girdileri ve değişmeyen
girdileri doğrular. Bunlar bias dönüşümü testleridir; requantization veya RTL
bit-exact eşleşme testi değildir. Testler checkpoint veya calibration gerektirmez.

Kişi A ve B birlikte bias rounding adayını ve gerçek quantization sınırlarını
onaylamalıdır. Bias tek başına INT32'ye sığsa bile MAC+bias taşabilir; bias ekleme
sırası ve accumulator overflow davranışı ayrıca kapanmalıdır. Sıfır/geçersiz
scale için fallback kararı verilmemiştir. M→M0/n, ağ bağlantısı, inference ve
hardware export bu çalışmanın kapsamında değildir. Gerçek bias artifact'i üretilmez.
