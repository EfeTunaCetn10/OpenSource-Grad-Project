# İlk böcek eğitim denemesi

3 epoch, batch size 128, seed 42, learning rate 0.001 ile tüm eğitim kümesi
kullanıldı. LeNet 3 giriş kanalı, 10 çıkış sınıfı ve 62.006 öğrenilen parametre
içeriyor. Çalışma CPU üzerinde tamamlandı.

`cnn_pipeline` dizininden çalıştırılan komut:

```bash
OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 python -u train.py \
  --dataset insects --data-dir data/insects \
  --stats data/insects/stats.json \
  --output-dir outputs/smoke_3epochs \
  --epochs 3 --batch-size 128 --workers 0 --seed 42 --skip-test
```

Tekrar çalıştırmak için yeni bir output-dir seçilmeli. Kod mevcut sonuçları
ezmeyi reddeder. Python ortamı: `/home/cgj/anaconda3/envs/pynq-cnn/bin/python`.

| Epoch | Train loss | Train accuracy | Val loss | Val accuracy |
|---|---:|---:|---:|---:|
| 1 | 2.0407 | %28.64 | 1.9357 | %30.16 |
| 2 | 1.8513 | %36.30 | 1.9115 | %32.53 |
| 3 | 1.7383 | %38.34 | 1.7506 | %37.94 |

Epoch eğitim kümesinden bir tam geçiştir. Batch, ağırlık güncellemesi için
birlikte işlenen görüntü grubudur; son batch 128'den küçük olabilir.
Cross-entropy loss, doğru sınıfa verilen olasılığı cezalandırır. Accuracy
en yüksek skora sahip sınıfın doğru olduğu örneklerin oranıdır.

İki loss da azaldı, validation accuracy yükseldi: bu kısa denemede öğrenme
gerçekleşti. 3 epoch nihai başarı veya overfitting hakkında güçlü bir sonuç
çıkarmak için yeterli değildir. Train ölçümleri rastgele veri artırma altında,
epoch boyunca değişen ağırlıklarla hesaplanır; validation sabit epoch sonu
ağırlıklarıyla ve rastgele dönüşüm olmadan ölçülür.

Sınıflar dengesizdir. Eğitimde en sık görülen `hfly_episyr` sınıfını her zaman
tahmin etmek validation üzerinde yaklaşık %25.42 accuracy verir. Bu nedenle
yalnız %10 rastgele tahmin seviyesiyle kıyaslamak yetersizdir. %37.94 bu basit
referansı aşar; sınıf bazında yeterli başarı gösterildiği anlamına gelmez.

En iyi checkpoint 3. epoch'tan `outputs/smoke_3epochs/insects/best.pt` dosyasına
kaydedildi. Yeniden yüklenerek mimariyle uyumu doğrulandı. Test değerlendirilmedi;
`test_metrics.json` oluşturulmadığı kontrol edildi. Sayısal sonuçlar
`insect_detect_smoke_training.json` içinde saklandı.

Sonraki adım daha uzun FP32 eğitimidir. Validation ile checkpoint seçimi
yapılmalı; son model sabitlenince test accuracy, macro recall ve confusion
matrix hesaplanmalıdır. Bu kısa denemenin checkpoint'i henüz donanım için
sabitlenmiş nihai model değildir.
