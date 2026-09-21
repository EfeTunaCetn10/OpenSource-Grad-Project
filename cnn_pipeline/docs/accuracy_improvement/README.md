# FP32 accuracy iyileştirmesi — 22 Eylül 2026

32×32 RGB, 10 etiketli LeNet mimarisi, veri ayrımı, normalizasyon, seed 42 ve
batch size 128 korundu. Sınıf ağırlıkları kullanılmadı. Üç koşu validation ile
karşılaştırıldı; en iyi checkpoint seçimi test yüklenmeden önce
`selected_model.json` içine kaydedildi. Yalnız seçilen model testte değerlendirildi.

## Sonuç

| Ölçüm | İlk FP32 baseline | Seçilen model | Fark (yüzde puan) |
|---|---:|---:|---:|
| Validation accuracy | %50.90 | **%55.41** | +4.51 |
| Validation macro recall | %34.72 | **%40.33** | +5.61 |
| Test accuracy | %50.31 | **%51.54** | +1.23 |
| Test macro recall | %34.79 | **%36.45** | +1.66 |

Test doğru sayısı 817/1624'ten **837/1624**'e çıktı. Testteki artış,
validation artışından belirgin biçimde küçük; tek seed koşusuyla istatistiksel
üstünlük veya genel kullanım başarısı iddia edilmez. Önceden görülmüş test
kümesidir, yeni bir dış veri doğrulaması değildir. Bu test sonucundan sonra
başka ayar seçilmedi.

Testte `bug` 0/27 ve `fly_sarco` 0/37 doğru tahminle zayıf kalıyor.
`beetle` 2/76, `hfly_sphaero` 4/49. Toplam accuracy artışı her sınıfta yeterli
başarı anlamına gelmez. Üç yeni koşunun başarısız sonuçları da saklandı.

## Deney zinciri

| Koşu | Değişiklik | Epoch | Val accuracy | Val macro recall |
|---|---|---:|---:|---:|
| Baseline | RandomResizedCrop + plateau, LR 0.001 | 30 | %50.90 | %34.72 |
| resize | Crop yerine tam görüntü resize | 30 | %51.75 | %36.11 |
| resize_lr3e4 | Resize koşusunda LR 0.0003 | 30 | %44.31 | %27.29 |
| resize_cosine | Resize, LR 0.001, cosine scheduler ve daha uzun eğitim | 60 | **%55.41** | **%40.33** |

İlk koşu yalnız kırpma tercihini, ikincisi buna göre başlangıç öğrenme
oranını değiştirdi. Son koşu **hem scheduler hem eğitim süresini değiştirdi**;
kazanımın bunlardan hangisine ne kadar ait olduğu ayrı ayrı ölçülmedi.
Scheduler seçeneği dışındaki optimizer ayarları korundu. RandomHorizontalFlip
ve ColorJitter devam etti. Kırpma kaldırılınca RNG tüketimi değiştiğinden
aynı seed, sonraki her augmentation örneğinin eşleştiği anlamına gelmez.

Görüntü kontrolünde 7.297 train görüntüsünün 619'unun kısa kenarı 32'den küçük,
934'ünün en-boy oranı varsayılan crop oran aralığının dışında bulundu. Bunlar
geometri sayımlarıdır; kırpmanın hata nedeni olduğunu tek başına kanıtlamaz.
Tam görüntüyü resize etmek kenarları korur, ancak en-boy oranını 32×32'ye
uyarlarken şekli değiştirebilir. Validation preprocessing zaten bu yöntemi kullanıyordu.

## Seçilen checkpoint

- Koşu: `resize_cosine`, en iyi epoch **51**.
- Dosya: `outputs/resize_cosine_60epochs/insects/best.pt`.
- SHA256: `9983f9d32e755f2821337a8e0c6c144a71069fd36e2da8b5235840251af1947e`.
- Aynı 62.006 parametreli mimari; donanım katman boyutları değişmedi.
- Mevcut adaylar arasında en yüksek validation accuracy; PTQ için güncel accuracy adayı.
- Nihai görev başarı eşiği sağlandı iddiası yok. Eski checkpoint'ler korunuyor.

Her koşunun `history.json`, `run_config.json`, `validation_metrics.json` ve
checkpoint/source hash bilgileri kendi alt klasöründe. Seçilen modelin test
confusion matrix'i `selected_test_metrics.json` dosyasında. Matris satırları
gerçek, sütunları tahmin edilen sınıftır; sınıf sırası validation raporundadır.

## Yeniden üretme

`cnn_pipeline` dizininden, henüz kullanılmamış output-dir ile:

```bash
OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 python -u train.py \
  --dataset insects --data-dir data/insects \
  --stats data/insects/stats.json \
  --output-dir outputs/resize_cosine_60epochs \
  --epochs 60 --batch-size 128 --workers 0 --seed 42 \
  --train-resize --scheduler cosine --skip-test

python analyze_validation.py \
  --checkpoint outputs/resize_cosine_60epochs/insects/best.pt \
  --data-dir data/insects --output-dir outputs/resize_cosine_validation_review
```

`--train-resize` yalnız train'deki crop'u değiştirir. `--scheduler cosine`
başlangıç LR'sini toplam epoch boyunca kosinüs eğrisiyle %1'ine kadar indirir.
Varsayılanlar eski davranışı korur: random crop ve plateau scheduler.
Checkpoint hâlâ en yüksek validation accuracy ile seçilir; son epoch değildir.

Test değerlendirmesinde aynı checkpoint/normalizasyonla test ImageFolder'ı,
128 batch, workers=0, ağırlıksız CrossEntropyLoss ve
`train.evaluate_with_macro_recall` kullanıldı. Model seçimi bundan önce kapatıldı.

## Doğrulama

- 17 test geçti; yeni test tam görüntü resize'ında kenarların korunduğunu,
  validation dönüşümünün değişmediğini ve `[N,3,32,32]` girişini kontrol eder.
- Her adayın validation confusion matrix toplamı 1.774 ve sınıf sırası eşleşti.
- Seçilen modelin test matrisi toplamı 1.624; doğru sayısı 837.
- Checkpoint yeniden yüklenerek validation accuracy ve SHA256 doğrulandı.
- Veri bölmesi SHA256 değeri önceki deneylerle aynı.
- Yeni koşularda eğitim başlangıcındaki kaynak hash'leri run_config'e kaydedilir.
