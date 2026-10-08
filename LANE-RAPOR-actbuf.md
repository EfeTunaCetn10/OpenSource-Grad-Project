# L2 actbuf lane raporu — 2026-10-08

## Yazılanlar

| Dosya | Satır | İçerik |
| --- | ---: | --- |
| `systolic-array-8x8/rtl/act_buffer.sv` | 134 | Sayaçlı adresleme, iki tek boyutlu BRAM bankası, senkron okuma, ping-pong ve sticky hata bayrakları |
| `systolic-array-8x8/tb/tb_act_buffer.sv` | 198 | `T_LAYOUT_ADDR_001`: iki tam frame, kısmi kolon tile'ı, maskelenmiş lane, okuma/yazma çakışması, elastik bekleme, sıra ve kapasite hataları |
| `systolic-array-8x8/model/act_buffer_ref.py` | 11 | Kilitli byte adres formülü ve coordinate-coded byte fonksiyonu |
| `systolic-array-8x8/model/gen_act_buffer_vectors.py` | 24 | İki 784-word referans frame'i üretir |
| `systolic-array-8x8/sim/run_tests.py` | +1 | Jeneratör ve kendi `actbuf_frame0.mem` sentinel çifti |
| `systolic-array-8x8/filelist.f` | +1 | Modül kaydı |

`in_col` tile içi kolon olarak kontrol edilir. Beklenen `(h,tile_x,col)` bağımsız sayaçlarla ilerler. Kabul edilen her doğru beat, maskesiz lane'leri sıfırlayıp aktif bankaya tek 64-bit word yazar. `in_last` yalnız son koordinatta kabul edilir. Okuma pasif bankadan bir clock sonra geçerli olur. Konfigürasyon frame boyunca sabit tutulmalıdır; iki kurulum çevriminde word plane tabanı hesaplanır.

ADR-018'deki 188/250 sayıları metinde türetilmemişti. Kilitli formülden `H=W=28` için `c=4,h=0,w=23 → 23×8+4=188` ve `c=2,h=1,w=3 → (28+3)×8+2=250` çıktı; testbench yorumunda da yer alır. Formül değiştirilmedi.

## Doğrulama

- `python sim/run_tests.py tb_act_buffer`: **1/1 PASS**.
- `python sim/run_tests.py`: **11/11 PASS**; önceden var olan 10 test de geçti.
- İki 28×28 frame: toplam **1568 kabul / 1568 write**; her word ve sıfırlanan lane 6–7 kontrol edildi. İkinci frame yazılırken ilk frame pasif bankadan okundu. Farklı kaynak pacing ve `rd_en` boşlukları ile iki akış, ayrıca `in_valid` yüksek tutulurken `in_ready` düşük olan iki kurulum çevrimi denendi.
- `python -c` ile referans fonksiyon checkpoint'leri: **188, 250**. `git diff --check` hata vermedi.

## OOC sentez

Vivado 2025.1, `xc7z020clg400-1`, 10 ns clock, `synth_design -mode out_of_context -flatten_hierarchy rebuilt -top act_buffer`:

| WNS | LUT | FF | RAMB36 | RAMB18 | DSP |
| ---: | ---: | ---: | ---: | ---: | ---: |
| **+4,560 ns** | 218 | 72 | 4 | 0 | 0 |

İki 784×64 array ayrı ayrı ikişer RAMB36'ya eşlendi. Raporlar `systolic-array-8x8/reports/actbuf_utilization.rpt` ve `actbuf_timing.rpt` altında üretildi. İlk OOC çalışması yalnız rapor klasörü bulunmadığından rapor yazma adımında durdu; klasör oluşturulup ikinci çalışma başarıyla tamamlandı.

## Mutasyon disiplini

Her mutant tek başına `rtl/act_buffer.sv` dosyasına uygulanıp `python sim/run_tests.py tb_act_buffer` ile XSim'de koşturuldu; her biri **simülasyona girip FAIL verdi**, ardından RTL geri alındı. İlk denemedeki kilitli XSim elaboration hataları kanıt sayılmadı; kilit temizlenip tekrar koşuldu.

| Mutant | Sonuç |
| --- | --- |
| Plane başlangıç adresine `+1` (off-by-one) | Yakalandı |
| Lane mask polaritesini ters çevir | Yakalandı |
| Kaynak byte lane sırasını ters çevir (yanlış bit alanı) | Yakalandı |
| `in_ready` sürekli 1 (backpressure atlandı) | Yakalandı |
| Reset `frame_count=1` | Yakalandı |

**5/5 yakalandı.** Mutantlar geri alındıktan sonra son tam regresyon yine 11/11 geçti.

## Açık kalanlar ve emin olmadıklarım

- `cfg_out_h`, `cfg_out_w`, `cfg_c_tile` için frame ortasında değişim protokolü tanımlı değil; modül iki kurulum çevriminde config'i kullanır, sonra sabit kalmasını bekler. Üst seviye bu koşulu sağlamalı.
- Başarılı `cfg_c_tile>0` depolama bu 784-word Conv1 örneğinde test edilmedi; tile 1'in ilk adresinin `DEPTH` dışında kalmasıyla overflow yolu test edildi. Daha büyük `DEPTH` ile çok tile'lı kullanım ayrıca doğrulanmalı.
- OOC sentez payı +4,560 ns; placement/route ve üst seviye entegrasyon ölçülmedi. Entegrasyon Faz 2'nin işidir.
- Reset bellek içeriğini temizlemez; `rd_valid` gelmeden `rd_data` anlamlı kabul edilmemelidir.
- ADR'deki 188/250 checkpoint'lerinin orijinal koordinatları verilmediği için yukarıdaki koordinatlar formülden seçildi; aynı sayıların ADR yazarının kastettiği koordinatlar olduğunu kanıtlayamam.

## Sahiplik

Görev metninin açık talimatı nedeniyle, sahiplik tablosunda L2'ye atanmadığı halde ortak `sim/run_tests.py` dosyasına bir jeneratör/sentinel satırı eklendi. Ortak `filelist.f` dosyasına kontratın izin verdiği bir satır eklendi. Başka lane'in RTL veya testbench dosyaları değiştirilmedi.
