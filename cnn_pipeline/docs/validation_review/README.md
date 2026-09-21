# Validation hata analizi ve sonraki deney

21 Eylül çalışma oturumunun kapanış incelemesi, 22 Eylül 2026'da tamamlandı.
Bu inceleme FP32 baseline checkpoint'ini kullanır; yeni eğitim başlatılmadı ve
test kümesi yeniden değerlendirilmedi.

## Confusion matrix nasıl okunur?

Satır gerçek etiketi, sütun tahmin edilen etiketi gösterir. Köşegen doğru
sınıflandırmalardır. Bir satırdaki bütün sayılar o sınıfın örnek sayısına eşittir.

Örneğin validation'daki 61 `fly_sarco` görüntüsünün tahminleri:

| Tahmin | Sayı |
|---|---:|
| fly | 48 |
| fly_small | 10 |
| hfly_eupeo | 2 |
| bee | 1 |
| fly_sarco (doğru) | 0 |

Bu sınıfın recall'u `0 / 61 = 0` olur. Ayrıca model bütün 1.774 validation
örneği boyunca hiç `fly_sarco` tahmin etmemiştir. Sorun yalnızca birkaç
sınırdaki örneğin karışması değildir.

Validation accuracy **%50.90**, macro recall **%34.72**. Test raporundaki
%34.79 ayrı kümenin sonucudur. [Sınıf tablosu](class_summary.md) ve
[tam matris](validation_metrics.json) bu klasördedir.

Diğer belirgin karışıklıklar:

- `beetle`: 85 örnekte 0 doğru; 40 tanesi `fly_small` tahmini.
- `bug`: 49 örnekte 6 doğru; 23 tanesi `beetle_cocci` tahmini.
- `hfly_eupeo`: 246 örnekte 41 doğru; 127 tanesi `hfly_episyr` tahmini.
- `hfly_sphaero`: 68 örnekte 9 doğru; 56 tanesi `hfly_episyr` tahmini.
- `hfly_episyr`: 451 örnekte 398 doğru; model toplam 678 kez bu etiketi seçiyor.

## Görüntü incelemesi

Yerel `outputs/validation_review/validation_examples.png` içinde her sınıftan
alfabetik dosya sırasındaki ilk hata ve sınıf listesinin ortasındaki örnek
incelendi. Orijinal görüntü ile 32×32'ye dönüştürülmüş hali yan yana gösterilir.
Bu seçki temsili veya rastgele bir örneklem değildir; hata mekanizmalarını
araştırmak içindir. Etiket doğruluğu hakkında uzman taksonomik kontrol yapılmadı.

Görsel gözlem: küçültme ince kanat/gövde ayrıntılarını azaltıyor; özellikle
`fly`/`fly_sarco` ve hoverfly etiketlerinde küçük görüntüler benzer görünebiliyor.
Bu gözlem tek başına modelin neden hata yaptığını kanıtlamaz.

`training_crop_examples.png` her sınıftan bir train görüntüsünü ve dört
RandomResizedCrop örneğini gösterir. Bazı örneklerde gövde kenarları/uzantılar
kesiliyor; bazıları zaten orijinal görüntünün kenarında. Bütün veri için kırpma
zararının sıklığı ölçülmedi. Flip ve ColorJitter bu görselde uygulanmadı;
eğitimdeki bütün augmentation hattının denetlenmiş olduğu iddia edilmez.

## Karar: tek değişkenli ağırlıklı loss deneyi

Eğitimde `hfly_episyr` 1.771, `fly_sarco` yalnız 221 görüntü içeriyor: yaklaşık
8 kat fark. Sınıf dengesizliği ve tahmin dağılımı, sınıf ağırlıklarını ilk
kontrollü deney olarak denemek için gerekçe sağlar; tek neden oldukları
kanıtlanmış değildir.

Önerilen ağırlık yalnız train sayılarından hesaplanır:

```text
weight[c] = toplam_train / (sınıf_sayısı × train_sınıf_sayısı[c])
```

Örneğin `fly_sarco` için yaklaşık 3.302, `hfly_episyr` için 0.412 elde edilir.
Aynı ham hatada nadir sınıfın göreli katkısı yaklaşık 8 kat olur. Bu işlem yeni
görüntü üretmez; loss hesabında sınıf hatalarının göreli ağırlığını değiştirir.

Bir sonraki deneyde yalnız CrossEntropyLoss'a bu ağırlıklar eklenecek.
Mimari, veri bölmesi, augmentation, seed, epoch sayısı ve optimizer/scheduler
ayarları korunacak. Checkpoint seçimi baseline ile aynı şekilde validation
accuracy ile yapılacak; seçilen model için validation macro recall ve tüm
sınıfların recall değerleri de karşılaştırılacak. Ağırlıklı eğitim loss'unun
mutlak değeri eski ağırlıksız loss ile doğrudan kıyaslanmayacak.

İyileşme önceden garanti değildir. Azınlık sınıflarının recall'u artarken
accuracy düşebilir; iki ölçüm birlikte raporlanacak. Test kullanılmayacak.
Başarı kabul eşiği belirlenmediği için deney sonucu otomatik olarak nihai
model kabul edilmeyecek. [Deney ayarları](next_experiment.json) kaydedildi;
**deney henüz uygulanmadı**.

## Tekrar üretme

`cnn_pipeline` dizininde yeni bir output-dir ile:

```bash
python analyze_validation.py \
  --checkpoint outputs/fp32_30epochs/insects/best.pt \
  --data-dir data/insects \
  --output-dir outputs/validation_review
```

Script yalnız train ve val klasörlerini okur. Checkpoint kimliği, confusion
matrix ve seçilen örneklerin yolları kaydedilir. Görüntü panoları yerelde kalır.
Doğrulama: matris toplamı 1.774; accuracy kayıtlı en iyi validation değeriyle
aynı; checkpoint SHA256 baseline manifest'iyle aynı.

## Oturum kapanışı

Veri hazırlama, normalizasyon, FP32 eğitim, hata analizi ve sonraki deneyin
planlanması tamamlandı. Bu oturum burada durduruldu. Sonraki konuşmada önce
bu bulgular ve ağırlıklı loss deneyi ele alınacak; henüz PTQ'ya geçilmedi.

Güncelleme (22 Eylül): planlanan deney tamamlandı; [sonuç raporu](../weighted_experiment/README.md). Yukarıdaki plan ilk inceleme anını kaydeder.
