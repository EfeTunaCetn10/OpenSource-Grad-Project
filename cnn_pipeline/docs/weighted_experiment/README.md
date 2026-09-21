# Sınıf ağırlıklı loss deneyi — 22 Eylül 2026

Planlanan tek değişkenli deney tamamlandı. Aynı train/validation ayrımı, seed
42, 32×32 RGB LeNet, augmentation, batch size 128 ve 30 epoch kullanıldı.
Model aynı seed ile sıfırdan başlatıldı; baseline checkpoint'ten sürdürülmedi.
Tek öğrenme hedefi değişikliği: train CrossEntropyLoss için
`weight[c] = N_train / (10 * train_count[c])`.

## Validation sonuçları

| Ölçüm | Baseline | Ağırlıklı loss | Fark (yüzde puan) |
|---|---:|---:|---:|
| Accuracy | %50.90 | %44.53 | -6.37 |
| Macro recall | %34.72 | %40.57 | +5.85 |

Checkpoint seçim kuralı aynı kaldı: en yüksek validation accuracy, eşitlikte
ilk epoch. Ağırlıklı koşuda **29. epoch** seçildi. 30. epoch aynı accuracy'ye
ulaştığı için checkpoint değiştirilmedi. Macro recall yalnız seçilen
checkpoint için hesaplandı; bütün epoch'lar arasında en iyi macro recall
checkpoint'i bulunduğu iddia edilmez.

[Test sonuçlarıyla değil, aynı validation kümesiyle](../validation_review/README.md)
karşılaştırıldı. Bu koşuda test değerlendirilmedi. Ham sayılar
`validation_metrics.json`, bütün eğitim geçmişi `history.json`, kimlik ve
farklar `comparison.json` içindedir.

## Ne değişti?

| Sınıf | Baseline recall | Ağırlıklı recall |
|---|---:|---:|
| fly_sarco | %0.00 | %44.26 |
| hfly_sphaero | %13.24 | %58.82 |
| beetle | %0.00 | %7.06 |
| bug | %12.24 | %20.41 |
| fly | %65.34 | %28.52 |
| hfly_episyr | %88.25 | %62.31 |

[Tüm sınıflar](class_comparison.md) incelendiğinde nadir sınıflardaki bazı
kazanımların yaygın sınıflardaki kayıplarla birlikte geldiği görülür.

Önemli örnek: model `fly_sarco`yu artık 27/61 örnekte buluyor, ancak toplam
154 kez bu etiketi tahmin ediyor. Bu tahminlerin yalnız 27'si doğru
(precision yaklaşık %17.53). Gerçek `fly` örneklerinin 93'ü `fly_sarco`
olarak tahmin edildi. Recall artışı tek başına sınıfın güvenilir biçimde
öğrenildiğini göstermiyor.

## Teknik kontroller

- Sınıf ağırlıkları yalnız train etiketlerinden ve görüntü dönüşümleri
  çalıştırılmadan hesaplandı; RNG durumunu değiştirmediği test edildi.
- Validation cross entropy ağırlıksız kaldı; eğitim loss'ları iki deney
  arasında doğrudan kıyaslanmamalı.
- Ağırlıklı epoch loss raporu örnek sayısına değil hedef sınıf ağırlıklarının
  toplamına göre birleştirildi; farklı batch boyutlarında test edildi.
- Optimizer ve scheduler ayarları aynı kaldı. Validation sonuçları farklı
  olduğu için ReduceLROnPlateau'nun ürettiği learning-rate zaman çizelgesi
  aynı olmak zorunda değildir; geçmişte kayıtlıdır.
- 1.774 validation örneği ve sınıf destekleri baseline ile eşleşti.
- `best.pt` yeniden yüklendi; SHA256 ve seçilen epoch kaydedildi.
- Test metrik dosyası oluşmadığı kontrol edildi. 12 test geçti.

## Tekrar üretme

`cnn_pipeline` dizininde, yeni output-dir kullanarak:

```bash
OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 python -u train.py \
  --dataset insects --data-dir data/insects \
  --stats data/insects/stats.json \
  --output-dir outputs/weighted_30epochs \
  --epochs 30 --batch-size 128 --workers 0 --seed 42 \
  --class-weighted --skip-test

python analyze_validation.py \
  --checkpoint outputs/weighted_30epochs/insects/best.pt \
  --data-dir data/insects --output-dir outputs/weighted_validation_review
```

CPU, OMP_NUM_THREADS=2 ve MKL_NUM_THREADS=2 kullanıldı. Ortam sürümleri ve
kaynak hash'leri `comparison.json`, sınıf sayıları/ağırlıkları `run_config.json`
içindedir. Checkpoint ve örnek görüntü panoları yerelde kalır.

## Karar

Bu sonuç doğruluk açısından baseline'ın yerini almaz; macro recall açısından
ise daha iyidir. İki checkpoint de korunur. Bu tek seed deneyi istatistiksel
üstünlük veya nihai kabul göstermez. Test üzerinden ayar yapılmadı.

Bir sonraki olası kontrollü deney, ağırlıkları karekök ile yumuşatmak olabilir:
`weight[c] = sqrt(N_train / (10 * train_count[c]))`. Böylece yaklaşık 8:1
olan göreli ağırlık oranı yaklaşık 2.83:1 olur. Bunun accuracy/recall dengesini
iyileştireceği henüz bilinmiyor; **uygulanmadı**. Mimari ve veri ayrımı
şimdilik değiştirilmedi; yeni deney kullanıcıyla konuşulduktan sonra ele alınacak.

Güncelleme: önerilen karekök deneyi tamamlandı; [üç deneyin karşılaştırması](../sqrt_weighted_experiment/README.md).
