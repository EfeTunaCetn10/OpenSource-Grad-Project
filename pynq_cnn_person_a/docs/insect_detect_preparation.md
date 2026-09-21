# Insect Detect: veri hazırlama, 21 Eylül 2026

Bu alt küme 10 veri seti etiketini sınıflandırır. Etiketler aynı taksonomik
seviyede olmak zorunda değildir; sonuçlar “10 biyolojik tür” olarak sunulmamalıdır.

## Sınıf seçimi

`none_*` ve `other` dışarıda bırakıldı. En az 300 görüntüsü, en az 20 çekim
günü olan ve tek bir günün görüntülerin en fazla %50'sini oluşturduğu etiketler
seçildi. Bu ölçüt tam 10 sınıf verdi. Bu, proje için bir mühendislik tercihi;
veri setinin resmî benchmark bölmesi veya donanım kontratı değildir.

## Neden görüntüleri tek tek karıştırmıyoruz?

Bir böceğin ardışık kareleri farklı kümelere düşerse test sonucu olduğundan
iyimser olabilir. Dosya adındaki YYYYMMDD bölümü grup olarak kullanılır.
Aynı gün bütün sınıflarda aynı kümeye atanır. Birebir dosya kopyaları başka
günlerde bulunsaydı bu günler de aynı grupta birleştirilecekti.

Gün bilgisi gerçek birey kimliği değildir. Farklı günlerdeki aynı böcek veya
yakın kopyalar için tam bağımsızlık garantisi yoktur. Bu yaklaşım yeni birey
genellemesinden ziyade ayrı çekim günlerinde performansı değerlendirmeye yarar.

Seed 42 ile 4000 aday grup bölmesi incelenir; sınıf başına %70/%15/%15
hedefine en yakın aday, oran hatalarının kareleri toplamıyla seçilir. Seçimde
model sonuçları kullanılmaz. Her sınıf üç kümede de bulunmalıdır. Günler
bölünmediği için hedef oranlar yaklaşık kalır. Test sonuçlarına bakarak bu
bölme yeniden seçilmemelidir.

## Oluşan veri

| Etiket | Train | Validation | Test |
|---|---:|---:|---:|
| bee | 660 | 188 | 213 |
| beetle | 359 | 85 | 76 |
| beetle_cocci | 521 | 120 | 135 |
| bug | 314 | 49 | 27 |
| fly | 1225 | 277 | 215 |
| fly_sarco | 221 | 61 | 37 |
| fly_small | 1154 | 229 | 279 |
| hfly_episyr | 1771 | 451 | 296 |
| hfly_eupeo | 815 | 246 | 297 |
| hfly_sphaero | 257 | 68 | 49 |
| **Toplam** | **7297** | **1774** | **1624** |

Train/validation/test sırasıyla 65/14/15 ayrı gün içerir. Sınıflar dengesizdir;
eğitim değerlendirmesinde accuracy yanında macro recall ve confusion matrix
incelenmelidir. Özellikle küçük sınıfların test ölçümleri daha değişken olabilir.

## Tekrar üretme

`pynq_cnn_person_a` dizininde, hedef klasör henüz yokken:

```bash
python prepare_insect_detect.py \
  --archive data/source/Insect_Detect_classification_v2.zip \
  --output-dir data/insects \
  --seed 42
```

Script mevcut hedefin üstüne yazmaz. Ham ZIP korunur. Veri klasörü Git'ten
hariç tutulur; `docs/insect_detect_split_summary.json` küçük, sürümlenebilir
özettir. Tam `data/insects/split_manifest.json` her görüntünün kaynak yolunu,
hedefini, gününü, grubunu ve SHA256 değerini içerir. Sınıf indeksleri alfabetik
sıradadır ve mevcut ImageFolder yükleyicisiyle uyumludur.

Kontroller: ZIP MD5 ve CRC doğrulandı; 10.695 görüntünün tamamı Pillow ile
açıldı ve kaynak SHA256 ile eşleşti. Kümeler arasında ortak gün veya birebir
dosya kopyası yok. Yeni bölme mantığının birim testleri mevcuttur.

## RGB normalizasyonu

7.297 train görüntüsü RGB olarak yüklenip 32×32 boyuta getirildi. `ToTensor`
ile piksel değerleri 0–255'ten 0–1 aralığına dönüştürüldü. Rastgele veri
artırma uygulanmadan her kanalın tüm pikselleri üzerinden mean/std hesaplandı:

| Kanal | Mean | Std |
|---|---:|---:|
| R | 0.4525560220 | 0.2273442530 |
| G | 0.4813439341 | 0.2079375972 |
| B | 0.1991688451 | 0.2056275747 |

```bash
python compute_stats.py --train-dir data/insects/train \
  --output data/insects/stats.json --workers 0
```

`workers=0` görüntü yüklemeyi ana süreçte yapar; hesaplama tanımını değiştirmez.
Her kanalda `z = (x - mean) / std` uygulanır. Örneğin kırmızı kanalda
`x=0.60`, yaklaşık `z=0.65` olur. Negatif normalleştirilmiş değerler normaldir;
kanal ortalamasından küçük piksel değerlerini gösterir. Normalizasyon INT8
quantization değildir; bu aşamada model girdisi float32 kalır.

Validation ve test için de train'den elde edilen aynı katsayılar kullanılır.
Rastgele veri artırma olmadan normalleştirilmiş train kümesinin kanal
ortalamalarının yaklaşık 0, standart sapmalarının yaklaşık 1 olduğu kontrol
edilir. Eğitimde rastgele crop/renk değişimi uygulandığı için tek bir eğitim
batch'inin tam olarak bu istatistikleri vermesi beklenmez.

Sayısal kontrol sonucu ve veri manifest'inin SHA256 değeri
`insect_detect_normalization.json` dosyasındadır. Mevcut yükleyicinin sınıf
indeksleri manifest ile karşılaştırılır; bir eğitim batch'i eğitilmemiş
LeNet'e verilerek `[32,3,32,32] -> [32,10]` akışı kontrol edilir. Bu işlem
eğitim veya başarı ölçümü değildir.

Sonraki ders kısa bir eğitim denemesi ve loss/accuracy yorumlama olacak.
Validation checkpoint seçimi için, test son değerlendirme için ayrılır.
