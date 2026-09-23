# Candidate PTQ policy: qparam ve INT8 ağırlık üretimi

Bu adım mevcut FP32 istatistiklerinden aday parametreler üretir. **Kabul edilmiş
hardware kontratı değildir.** Integer CNN, golden reference, bias quantization,
M0/n veya ağırlık-bankası export'u içermez. Gerçek calibration yeniden
çalıştırılmadı; yeni örnek seçilmedi, model forward veya accuracy hesabı yapılmadı.

## Aday sayısal politika

| Alan | Bu deney adayı |
|---|---|
| Ağırlık | Signed INT8, symmetric, per-output-channel, axis=0 |
| Aktivasyon | Signed INT8, symmetric, per-tensor |
| Zero-point | 0 |
| İlk quantizer aralığı | [-127,127] |
| Scale | absmax / 127 |
| İlk float→integer rounding | Half-up: tie +∞ yönüne |
| Sıfır/sabit aralık | Açık hata; fallback veya epsilon atanmaz |

`q = clip(round_half_up(x / scale), -127, 127)`.
Bölme ve rounding CPU float64'te yapılır; **INT8 cast clipping'den sonradır**.
Half-up için örnek: -1,5→-1; -0,5→0; +0,5→1; +1,5→2. Python/PyTorch'un
varsayılan bankers rounding davranışına dayanılmaz. Uygulama matematiksel
`floor(x+0.5)` yerine `floor(x) + [x-floor(x) >= 0.5]` kullanır; bu, tie'ın hemen
altındaki temsil edilebilir değerlerde toplama nedeniyle yanlış tie oluşmasını
önler. Float64 bölme yine kayan nokta aritmetiğidir; donanım sözleşmesi değildir.

ADR-003'teki **requantization** round-half-up ve ReLU için [0,127], diğer çıkışlar
 için [-128,127] saturation kuralları değiştirilmedi. Buradaki dar [-127,127]
aralığı **ilk float quantizer adayına** aittir; requantizer uygulanmadı.

Sıfır aralığı yalnız tamamen sıfır tensor anlamına gelmez. Bütün elemanları
aynı ve sıfırdan farklı olan kanal da bu sürümde hata üretir. Hata hangi
katman/gözlem noktasında olduğunu bildirir; kullanıcı kararı olmadan fallback
scale veya çıktı üretilmez.

## Girdiler ve denetlenebilirlik

İstatistik girdisi önceki çalışma dokümanındaki gerçek dosyadır:
`outputs/activation_calibration/seed42_epoch51_20260924_run01/statistics.json`.
Dosya eksikse `FileNotFoundError` ile durulur; uydurma değer veya yeniden
calibration yoktur.

Doğrulamalar:

- Checkpoint SHA256: selected_model.json, statistics ve selection manifest
  kayıtlarıyla aynı olmalı. Seed=42, epoch=51 ve sınıf sırası doğrulanır.
- Statistics içindeki selected_model.json hash'i, calibration manifest hash'i,
  split/seçim/preprocessing bilgileri mevcut dosyalarla eşleştirilir.
- Manifest SHA256'sı yanındaki summary.json ile de karşılaştırılır. Manifest
  kayıtlarının train üyeliği, tekilliği, etiketleri, sınıf sayıları ve görüntü
  içerik hash'leri kontrol edilir. Görüntüler yalnız byte hash'i için okunur;
  loader oluşturulmaz, yeni seçim yapılmaz.
- Kaynak split manifest hash'i varsa doğrulanır. İstatistiği üreten model/data/
  calibration/observer kaynak hash'leri mevcut dosyalarla eşleştirilir.
- State dict strict yüklenir; model ileri çalıştırılmaz. Ağırlık/bias istatistikleri
  checkpoint'ten yeniden hesaplanıp statistics ile birebir karşılaştırılır.
- Aktivasyon nokta kümesi, shape, örnek/eleman sayıları, FP32/per-tensor tanımı,
  min/max/absmax tutarlılığı ve sonluluk kontrol edilir.

Bu, kimlik ve tutarlılık kontrolüdür; saklanan aktivasyon extrema'sını bağımsız
olarak tekrar ölçmek değildir. Önceki statistics dosyasının ayrı bir imzalı
checksum'u yoktur. Bu koşu dosyanın SHA256'sını `input_sha256` içinde sabitler;
içeriği ve kimlik alanları birlikte bilinçli değiştirilmiş bir kaydı kriptografik
olarak doğrulanmış saymaz. Okuma sırasında girdilerin başka süreçlerce
 değiştirilmediği varsayılır; temel girdi dosyalarının hash'leri işlem sonunda
tekrar kontrol edilir.

## Kullanım ve çıktılar

Repo kökünden mevcut `pynq-cnn` ortamında:

```bash
python cnn_pipeline/quantization.py \
  --checkpoint cnn_pipeline/outputs/resize_cosine_60epochs/insects/best.pt \
  --statistics cnn_pipeline/outputs/activation_calibration/seed42_epoch51_20260924_run01/statistics.json \
  --selection-manifest cnn_pipeline/outputs/calibration/seed42_100perclass_20260924/selection_manifest.json \
  --selected-model cnn_pipeline/docs/accuracy_improvement/selected_model.json \
  --output-dir cnn_pipeline/outputs/quantization/seed42_epoch51_candidate_run02
```

CLI 10 sınıf × 100 örneklik mevcut seçimi bekler. Mevcut output-dir reddedilir;
çıktı yalnız `outputs/quantization/` altında yeni run klasörüne yazılır.
Bugünkü gerçek üretim dizini: `seed42_epoch51_candidate_run01`.

- `qparams.json`: candidate policy, altı aktivasyon scale'i, 236 output-channel
  scale'i ve zero-point değerleri, shape/axis, hata metrikleri, kaynak/girdi hash'leri.
- `candidate_weights_int8.pt`: beş adet `*.weight` INT8 tensoründen oluşan sözlük.
  Conv `[out,in,kH,kW]` ve Linear `[out,in]` düzeni korunur. Bias içermez.
  Bu dosya **çalıştırılabilir INT8 model veya hardware export değildir**.
  Dosyanın SHA256'sı qparams.json içine kaydedilir.

`outputs/` mevcut Git ignore kapsamındadır. Checkpoint'e yazılmaz.

## Gerçek koşu sonuçları

Checkpoint SHA256:
`9983f9d32e755f2821337a8e0c6c144a71069fd36e2da8b5235840251af1947e`.
Calibration selection manifest SHA256:
`a741a55b8bb754c73e8a8b43e11851011a1dda2f3841bb07b3460477e68aef3e`.

| Aktivasyon | Aday scale |
|---|---:|
| Normalize giriş | 0.0306659120 |
| Conv1 ReLU (`features.1`) | 0.0398631809 |
| Conv2 ReLU (`features.4`) | 0.0700418818 |
| FC1 ReLU (`classifier.2`) | 0.1383092985 |
| FC2 ReLU (`classifier.4`) | 0.1594079085 |
| FC3 logits (`classifier.5`) | 0.2866307657 |

| Ağırlık | Kanal scale min–max | Dequantization MAE | Max mutlak hata |
|---|---:|---:|---:|
| Conv1 | 0.0011035524–0.0017012330 | 0.0003058892 | 0.0008396204 |
| Conv2 | 0.0010457944–0.0022330249 | 0.0003765111 | 0.0011019260 |
| FC1 | 0.0004553402–0.0031965039 | 0.0003876241 | 0.0015901500 |
| FC2 | 0.0007568159–0.0034162123 | 0.0004462719 | 0.0016852171 |
| FC3 | 0.0021503863–0.0035008054 | 0.0006806552 | 0.0017274786 |

61.770 ağırlıktan **0'ı clipping gerektirdi (%0)**. 247 değer ±127 uç koduna
ulaştı (yaklaşık %0,400). Bu iki ölçüm farklıdır:

- `clipping_rate`: rounding sonrasında [-127,127] dışında kalan ve clamp ile
  değiştirilen elemanların oranı.
- `endpoint_rate`: sonuçta -127 veya +127 olan elemanların oranı; doğal olarak
  uç koda eşlenen extrema da buna dahildir. Bu oranı clipping kaybı saymamak gerekir.

JSON ayrıca kanal başına clipping sayısı/MAE ve katman RMSE'sini içerir.
Sıfır/sabit ağırlık kanalı veya aktivasyon aralığı görülmedi.

Aktivasyon clipping/endpoint oranları **ölçülmedi (`null`)**: eski rapor yalnız
extrema içeriyor, tensor/histogram saklamıyor. Aday absmax ölçeği kayıtlı aralığı
kapsar; bu bilgi ampirik saturation oranı veya yeni görüntüler için garanti
olarak sunulmaz. Bunun için ileri bir görevde aynı seçim üzerinde ölçüm gerekir.

## Testler ve kapsam

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 \
  python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

**74 test geçti: 51 mevcut + 23 yeni test durumu.** Elle hesaplanan signed tie,
clipping/cast sırası, per-channel ekseni, per-tensor scale, NaN/Inf, hatalı scale,
sıfır/sabit aralık, kimlik/istatistik bozulması, görüntü hash uyuşmazlığı,
eksik statistics, değişmeyen checkpoint/calibration dosyaları, çıktı yeniden
yükleme ve overwrite reddi kapsandı. Sentetik fixture'lar gerçek dataset gerektirmez.
Sentetik testlerden sonra mevcut gerçek dosyalarla aday üretimi çalıştırıldı.

Yeni dosyalar: [quantization.py](../../quantization.py),
[test_quantization.py](../../tests/test_quantization.py), bu README.
Eski kaynaklar, raporlar ve ADR'ler değiştirilmedi. Paket kurulmadı;
commit/push/PR/merge yapılmadı.

Açık kalanlar: bu aday politikanın değerlendirilip kabulü, sıfır/sabit aralık
fallback'i, aktivasyon clipping ölçümü, gerçek RTL quantization sınırları,
bias/accumulator ve M0/n politikaları. Pool/Flatten için önceki scale aktarım
önerisi korunur; her gözlem noktası nihai quantization sınırı ilan edilmez.
Bu adım inference doğruluğu veya integer golden doğruluğu iddiasında bulunmaz.
