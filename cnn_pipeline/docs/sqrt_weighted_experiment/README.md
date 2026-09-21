# Karekök sınıf ağırlıkları deneyi — 22 Eylül 2026

30 epoch eğitim tamamlandı. Önceki ağırlıklı deneyden tek hedef değişikliği,
train sınıf ağırlıklarının karekökünü almaktır:

```text
weight[c] = (N_train / (10 * train_count[c])) ** 0.5
```

Aynı seed 42 ile sıfırdan eğitim, aynı veri ayrımı, mimari, augmentation,
normalizasyon, optimizer/scheduler ayarları ve batch size 128 kullanıldı.
Validation loss yine ağırlıksızdır. Checkpoint validation accuracy'ye göre
seçildi: **26. epoch**. Test kümesi değerlendirilmedi.

## Üç deneyin validation karşılaştırması

| Deney | Accuracy | Macro recall |
|---|---:|---:|
| Ağırlıksız baseline | %50.90 | %34.72 |
| Ters frekans, power=1 | %44.53 | %40.57 |
| Karekök, power=0.5 | %47.52 | %37.24 |

Karekök ağırlıklar tam ağırlığa göre accuracy'yi **2.99 yüzde puan** artırdı,
macro recall'u **3.32 yüzde puan** azalttı. Baseline'a göre accuracy **3.38
puan düşük**, macro recall **2.53 puan yüksek**. Dolayısıyla yumuşatma iki
önceki sonucun arasında bir denge üretti; her iki ölçümde üstün bir sonuç yok.
Bu tek seed deneyi istatistiksel üstünlük göstermez.

## Sınıf örneği: recall ve precision

`fly_sarco` için:

| Deney | Doğru / gerçek örnek | Recall | Toplam fly_sarco tahmini | Precision |
|---|---:|---:|---:|---:|
| Baseline | 0 / 61 | %0.00 | 0 | Tanımsız (tahmin yok) |
| Ters frekans | 27 / 61 | %44.26 | 154 | %17.53 |
| Karekök | 13 / 61 | %21.31 | 43 | %30.23 |

Karekök modeli daha az `fly_sarco` örneği buluyor, fakat bu etiketi seçtiğinde
öncekinden daha sık doğru çıkıyor. Gerçek `fly` görüntülerine yanlışlıkla
`fly_sarco` deme sayısı 93'ten 25'e düştü. Bu, ağırlığın karar dengesini
nasıl değiştirdiğine bir örnektir; sınıflandırma sorununun çözüldüğü anlamına gelmez.

`beetle` hâlâ yalnız 2/85, `bug` 7/49 doğru örneğe sahip.
[Bütün sınıfların karşılaştırması](class_comparison.md) ve
[ham validation matrisi](validation_metrics.json) kaydedildi.

## Uygulama ve kontrol

`--class-weighted` önceki davranışı korur (power=1). Yeni
`--class-weight-power 0.5` seçeneği ağırlıkları yumuşatır. Power 0 tüm
sınıflara 1 ağırlık verir. Desteklenen aralık [0,1]; yanlış veya NaN güçler
reddedilir. Ağırlıklandırma bayrağı olmadan özel güç kullanımı hata verir.

16 test geçti. Karekök ağırlıkların kareleri önceki ağırlıklarla eşleşti;
train sayıları toplamı 7.297; validation matris toplamı 1.774 ve sınıf
support değerleri diğer deneylerle aynı. En iyi checkpoint tekrar yüklenip
kayıtlı accuracy ve epoch ile karşılaştırıldı. Test metrik dosyası üretilmedi.

```bash
# cnn_pipeline dizininde; output-dir henüz kullanılmamış olmalı
OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 python -u train.py \
  --dataset insects --data-dir data/insects \
  --stats data/insects/stats.json \
  --output-dir outputs/sqrt_weighted_30epochs \
  --epochs 30 --batch-size 128 --workers 0 --seed 42 \
  --class-weighted --class-weight-power 0.5 --skip-test

python analyze_validation.py \
  --checkpoint outputs/sqrt_weighted_30epochs/insects/best.pt \
  --data-dir data/insects --output-dir outputs/sqrt_weighted_validation_review
```

CPU'da OMP_NUM_THREADS=2, MKL_NUM_THREADS=2 kullanıldı. Sürümler, kaynak ve
checkpoint SHA256 değerleri `comparison.json`; eğitim ayarları ve ağırlıklar
`run_config.json`; epoch sonuçları `history.json` içindedir. Scheduler aynı
kuralla validation accuracy'ye tepki verir; farklı koşularda learning-rate
zaman çizelgesinin aynı olması beklenmez. Bütün checkpoint'ler yerelde korunur.

## Sonuç

Accuracy önceliğinde baseline, macro recall önceliğinde tam ağırlıklı model
önde. Karekök modeli bu iki hedef arasında kalıyor. Başarı hedefi netleşmeden
karekök checkpoint'i nihai model ilan edilmedi. Yeni eğitim veya test
değerlendirmesi başlatılmadı. Ağırlıklarla oynayarak bütün sınıfların sorununu
çözdüğümüz söylenemez; sonraki karar bu üç deney birlikte değerlendirilerek verilmeli.
