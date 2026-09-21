# Insect Detect FP32 başlangıç modeli — 21 Eylül 2026

30 epoch eğitim tamamlandı. Validation accuracy ile **26. epoch** seçildi.
Seçilen checkpoint test kümesinde değerlendirildi; test sonucu checkpoint
seçiminde kullanılmadı.

| Ölçüm | Sonuç |
|---|---:|
| En iyi validation accuracy | %50.90 |
| Test accuracy | %50.31 (817 / 1624) |
| Test macro recall | %34.79 |
| Test loss | 1.4379 |

Kesin değerler `test_metrics.json` dosyasındadır. Confusion matrix satırları
gerçek, sütunları tahmin edilen sınıftır. Sıralama `model_manifest.json`
içindeki `class_names` listesidir.

## Yorum ve sınırlar

Accuracy bütün görüntülerdeki doğru tahmin oranıdır. Macro recall önce her
sınıfın kendi doğru tahmin oranını hesaplar, sonra 10 sınıfın ortalamasını alır.
Sınıflar dengesiz olduğundan ikisi birlikte değerlendirilmelidir.

`bug` (0/27) ve `fly_sarco` (0/37) sınıflarında recall sıfırdır.
`beetle` (2/76) ve `hfly_sphaero` (2/49) da zayıftır. `hfly_episyr`
251/296 doğru örnekle yaklaşık %84.80 recall verir. Genel %50.31 sonucu
her sınıfta benzer başarı sağlandığı anlamına gelmez.

Bu checkpoint **PTQ ve donanım doğrulaması için başlangıç referansıdır**;
sınıflandırma görevinin başarı eşiğini geçtiği iddia edilmez. Başarı eşiği
henüz tanımlanmadı. Etiketler de 10 ayrı biyolojik tür olarak sunulmamalıdır.
Yeni eğitim denemeleri yapılırsa seçim validation üzerinden yapılmalı;
görülmüş test kümesi tekrar tekrar model ayarlamak için kullanılmamalıdır.

Son epoch validation başarısı %50.68'dir. Son ağırlıkları kullanmak yerine
validation'da %50.90 veren 26. epoch seçildi. Son kısımda gelişim sınırlıdır;
yalnız epoch sayısını artırmanın sorunu çözeceği varsayılmamalıdır.

## Tekrar üretme

Önce `../insect_detect_preparation.md` ile aynı veri bölmesini ve stats.json'u
üretin. `cnn_pipeline` dizininde, henüz kullanılmamış bir output-dir ile:

```bash
OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 python -u train.py \
  --dataset insects --data-dir data/insects \
  --stats data/insects/stats.json \
  --output-dir outputs/fp32_30epochs \
  --epochs 30 --batch-size 128 --workers 0 --seed 42
```

Çalışma CPU'da `/home/cgj/anaconda3/envs/pynq-cnn/bin/python` ile yapıldı.
Sürümler, eğitim ayarları, kaynak dosyaların ve veri manifest'inin SHA256
değerleri `model_manifest.json` içindedir. Seed, farklı donanım ve kütüphane
sürümlerinde bit düzeyinde aynı eğitim sonucunu garanti etmez.

Yerel checkpoint: `outputs/fp32_30epochs/insects/best.pt`.
Dosyanın SHA256 kimliği manifest'te saklandı; PTQ bu checkpoint'i kullanmalıdır.
Checkpoint ve görüntüler Git'e dahil değildir. Bu klasörde küçük sonuç
raporları, confusion matrix ve bütün epoch geçmişi tutulur. Başka bilgisayarda
aynı ağırlıkları kullanmak için checkpoint ayrıca aktarılmalı ve SHA256
doğrulanmalıdır; yeniden eğitim aynı dosyayı garanti etmez.

## Kontrol

- 30 epoch geçmişi mevcut.
- Checkpoint yeniden yüklenip RGB, 10 sınıf ve `[1,3,32,32] -> [1,10]` kontrol edildi.
- Confusion matrix toplamı 1624; köşegen toplamı accuracy ile uyumlu.
- Önceki 3 epoch denemesinde test değerlendirilmedi.
- Veri bölmesi ve model testleri: 9 passed.
