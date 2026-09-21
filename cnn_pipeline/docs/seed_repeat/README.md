# Aynı eğitim tarifinin farklı seed ile tekrarı

22 Eylül 2026. Bu koşu yeni bir eğitim ayarı aramak için değil, seçilen
60 epoch tam görüntü/cosine tarifinin rastgele başlangıca duyarlılığını
kontrol etmek için çalıştırıldı. Model sıfırdan başlatıldı; eski checkpoint'e
60 epoch daha eklenmedi.

## Seed neyi değiştiriyor?

Seed, rastgele sayı üreticisinin başlangıcını belirler. Bu kodda `--seed`
modelin ilk ağırlıklarını ve workers=0 altında rastgele görüntü dönüşümlerini
etkiler. Train/validation/test ayrımı manifest ile sabittir. DataLoader'ın
ayrı generator seed'i kodda 42 olduğundan batch sırası da iki koşuda aynı
kalır. Dolayısıyla bu deney bütün rastgelelik kaynaklarını değiştiren bir
çoklu-seed çalışması değildir; başlangıç/augmentation duyarlılığı kontrolüdür.

Seed 42 ve 123 koşularının run_config dosyaları karşılaştırıldı: yalnız `seed`
ve `output_dir` farklı. Kod hash'leri, mimari, veri bölmesi, normalizasyon,
optimizer, scheduler, 60 epoch, batch size 128, workers=0 ve CPU aynı.

## Validation karşılaştırması

| Ölçüm | Seed 42 | Seed 123 |
|---|---:|---:|
| En iyi accuracy | %55.41 | %54.62 |
| Seçilen checkpoint macro recall | %40.33 | %37.69 |
| En iyi epoch | 51 | 40 |
| 60. epoch accuracy | %55.13 | %53.66 |

İki koşuda da checkpoint aynı kuralla seçildi: en yüksek validation accuracy,
eşitlikte ilk epoch. Seçilen checkpoint sonuçları karşılaştırıldığında
accuracy farkı **-0.79 yüzde puan**, macro recall farkı **-2.63 yüzde puan**.

Bu iki başlangıçta genel accuracy yakın çıktı. Tekrar koşusu doğruluğu
artırmadı; zaten amacı artış garantisi değildi. İki seed, istatistiksel
kararlılık veya her başlangıçta aynı başarı garantisi için yeterli değildir.
Baseline'ın bütün ayarları için seed tekrarları yapılmadığından, önceki
ayarlar üzerindeki üstünlüğe ilişkin kapsamlı çoklu-seed iddiası da yoktur.

Sınıflar aynı ölçüde kararlı değil: `bug` validation recall'u %24.49'dan
%8.16'ya, `hfly_eupeo` %29.27'den %22.76'ya düştü. `fly_sarco` her iki koşuda
da 2/61 doğru. [Bütün sınıflar](class_comparison.md) ve confusion matrix
`validation_metrics.json` içinde kayıtlı.

## Karar

Seed 42 checkpoint'i hem validation accuracy hem macro recall'da daha iyi;
mevcut seçilen model değiştirilmedi. Seed 123 ayrı klasörde korunur.
**Test kümesi değerlendirilmedi.** Bu koşunun test başarısı bilinmiyor;
seed 42'nin %51.54 test accuracy'si bu modele atfedilmemelidir.

Rastgele daha iyi seed aramaya devam edilmedi. Bu tekrar tamamlandı.
Bir sonraki karar, zayıf sınıfların veri/etiket incelemesi ve PTQ takvimiyle
birlikte verilmeli; yalnız seed değiştirerek sınıf sorunlarının çözülmesi
beklenmemeli.

## Tekrar üretme

`cnn_pipeline` dizininde yeni bir output-dir ile:

```bash
OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 python -u train.py \
  --dataset insects --data-dir data/insects \
  --stats data/insects/stats.json \
  --output-dir outputs/resize_cosine_seed123_60epochs \
  --epochs 60 --batch-size 128 --workers 0 --seed 123 \
  --train-resize --scheduler cosine --skip-test

python analyze_validation.py \
  --checkpoint outputs/resize_cosine_seed123_60epochs/insects/best.pt \
  --data-dir data/insects --output-dir outputs/seed123_validation_review
```

Çalışan ortam önceki koşuyla aynı `pynq-cnn` Python ortamıdır. Kaynak hash'leri
`run_config.json` içinde; checkpoint ve veri bölmesi SHA256 değerleri
`comparison.json` içinde. Checkpoint, sınıf sırası, 60 epoch geçmişi ve aynı
1.774 validation örneğinin değerlendirildiği doğrulandı. `test_metrics.json`
oluşmadığı kontrol edildi. Eğitim kodunda değişiklik yapılmadı.
