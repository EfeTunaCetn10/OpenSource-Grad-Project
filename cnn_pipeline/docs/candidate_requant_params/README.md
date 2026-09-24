# Candidate software parameters: M0/n arayüzü

`candidate_requant_params.py` içindeki
`candidate_requant_params(s_x, s_y, s_w)` sonraki saf integer çalışmalar için
bağımsız bir yazılım arayüzüdür. Nihai RTL üretim algoritması, register paketi
veya bit-exact FPGA parametresi değildir. Dosya okumaz/yazmaz; checkpoint,
dataset, PyTorch veya quantized runtime gerektirmez.

## Kullanım ve dönüş değeri

```python
from candidate_requant_params import candidate_requant_params
p = candidate_requant_params(1.0, 1.0, [0.5, 0.25])
assert p['M0'] == [65536, 65536]
assert p['n'] == [17, 18]
```

Elle kontrol: `65536/2^17 = 0.5`, `65536/2^18 = 0.25`.
Her kanal için `M = s_x*s_w[c]/s_y` hesaplanır. `channels` listesi orijinal
kanal sırasıyla `channel`, `M`, `M0`, `n`, `M_approx`, `absolute_error`,
`relative_error`, `exact_float64`, `status`, `anomalies` alanlarını içerir.
Üst düzey `role` bunun candidate software parameters olduğunu belirtir.

M0/n seçimi tamamen `multiplier_analysis.analyze_multiplier(M)` tarafından
yapılır. n tarama, rounding ve seçim kriteri bu modülde tekrar uygulanmaz.
Seçilen çiftin built-in int olması, M0=[65536,131071] ve geçici n=[1,49]
aralığı doğrulanır; `requant_raw(0,M0,n)` mevcut genişlik kontrollerini de
çalıştırır. Bu kontrol MAC/bias/ağ entegrasyonu değildir.

Örnek üst sınır: `M=131071.5/2^18` için mevcut analiz n=18 adayını reddeder,
n=17/M0=65536 adayını seçer. Arayüz bu sonucu ve anomali açıklamasını olduğu
gibi taşır; 131072'yi 131071'e clamp etmez.

## Girdiler ve hata davranışı

s_x/s_y built-in int veya float scalar; s_w boş olmayan, düz list/tuple
olmalıdır. Her kanal aynı scalar kurallarına tabidir. Bool, string, tensor,
iç içe/ragged yapı ve otomatik tür dönüşümü gerektiren nesneler reddedilir.
NaN/Inf, sıfır/negatif scale ve float64'e sığmayan integer reddedilir.

Çarpım ve bölüm Python binary64 ile hesaplanır. Her ara sonuç sonlu ve normal
pozitif float64 olmalıdır: sıfıra underflow, subnormal sonuç ve overflow açık
hata üretir. Subnormal ara sonuçların da reddi koruyucu **yazılım kapsamıdır**,
RTL politikası değildir. Aritmetik yeniden düzenlenerek kayıp gizlenmez.
Yuvarlama/hata ölçümleri gerçek sayılar üzerinde sınırsız hassasiyet iddiası
taşımaz; `exact_float64` yalnız hesaplanan M ile eşitliktir.

Seçilemeyen kanalın indeksi ve M değeri hatada yer alır. Bir kanal başarısızsa
kısmi liste dönmez. Girdiler değiştirilmez; clamp, fallback veya export yoktur.

## Doğrulama

57 sentetik test: elle hesaplanan çiftler, farklı kanal scale'leri/sıra,
mevcut selected_candidate ile tutarlılık, requant kabulü, üst sınır anomalisi,
tüm çağrının reddi, tip/shape/scale ve ara işlem hataları, deterministik sonuçlar,
girdi değişmezliği ve geçersiz seçilmiş çifte karşı kontrat kontrolleri.

Yerel kontrol, `verify_qparams` ile mevcut qparams ve kaynak kimlik/hash'lerini
önce doğrular. Katman eşlemesi `multiplier_analysis.LAYERS` üzerinden alınır;
ayrı sabit tablo eklenmez. Arayüz sonuçları hem yeni `analyze_qparams` hesabıyla
hem mevcut diagnostic kaydıyla karşılaştırıldı: **236/236 kanal eşleşti**.
Diagnostic tek başına güvenilir kaynak sayılmadı; işlem sonu kaynak hash'leri
aynı kaldı. Bu kontrol gerçek inference/calibration değildir; kaynak eksikliği
ve kimlik hatası için doğrulama gevşetilmez.

Kaynaklar:
- `outputs/quantization/seed42_epoch51_candidate_run01/qparams.json`
- `outputs/multiplier_analysis/seed42_epoch51_candidate_run01/diagnostic.json`

## Açık kararlar

Mevcut M0 rounding/n seçimi ve üst sınır davranışı aday olmaya devam eder.
n=0 ve n=50…63 için yeni yol tanımlanmadı; signed 50-bit uyumsuzluğu RTL ekibiyle
kapanmalıdır. Gerçek quantization sınırları ve MAC+bias overflow politikası da
açıktır. Bu çalışma RTL/FPGA eşleşmesi kanıtlamaz, ADR değiştirmez ve hardware
parametre dosyası üretmez. Önceki modüller değiştirilmedi.
