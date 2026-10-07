---
title: ADR-011 Ağırlık Bellek Adresleme
created: 2026-08-28
modified: 2026-10-07
type: decision
status: kabul edildi
tags: [dnn-accelerator, adr, kontrat, rtl, ml]
---

# ADR-011: Ağırlık Bellek Düzeni / Adresleme Şeması

## Durum
Kabul edildi — 2026-08-28

## Bağlam
Abstract §5'te ve Proje Kararları'nda tanımlanan üç kritik kontrattan üçüncüsü: Kişi A'nın
(ML) PyTorch'tan export ettiği quantize ağırlıkların, Kişi B'nin (RTL) BRAM okuma/adresleme
şemasıyla birebir örtüşmesi. [[ADR-004 Systolic Array Boyutu|ADR-004]] (8×8, output-stationary)
ve [[Roadmap]] §5'teki doğrudan/streaming convolution (im2col değil)
kararlarının üzerine inşa ediliyor. Ağırlık depolama yeri zaten MVP kapsamında BRAM/ROM'a
önceden yükleme olarak belirlenmişti (ADR-010); bu karar onu teyit edip üstüne adresleme
şemasını ekliyor.

Output-stationary dataflow'da ağırlıklar PE içinde sabit kalmıyor — weight-stationary'nin
aksine her cycle array'e sistolik olarak akıyor (diagonal wavefront). Bu yüzden asıl soru
ağırlığın BRAM'dan hangi sırayla okunup array'e ne zaman besleneceği.

## Karar
**Ağırlıklar PyTorch'un native `[out_channels, in_channels, kH, kW]` contiguous sırasıyla
(dönüşümsüz) export edilecek; `c_out mod 8` ile 8 BRAM bankasına dağıtılacak (her banka bir
array satırına/çıktı kanalına özel); banka-içi adres `t*K + k` formülüyle hesaplanacak;
katman başına 8 adet `.coe` dosyası olarak Vivado Block Memory Generator'a yüklenecek.**

## Detay

**PyTorch tarafı (Kişi A):** Hiçbir yeniden sıralama yok. Conv ağırlık tensörü zaten
`[out_channels, in_channels, kH, kW]` C-order (kW en hızlı değişen eksen); her `c_out` dilimi
bellekte ardışık `K = in_channels × kH × kW` elemanlık blok. FC katmanlar `kH=kW=1` özel
durumu olarak aynı şemaya giriyor — Roadmap §5 Aşama 3'ün "aynı MAC altyapısını FC'de
yeniden kullan" hedefiyle örtüşüyor.

**Banking:** 8 banka, her banka bir array satırına (çıktı kanalı grubuna) özel:
`bank = c_out mod 8`. `out_channels > 8` olduğunda (örn. LeNet conv2: 16 kanal)
`tile = c_out div 8` ile ikinci geçiş yapılır — bu, zaten planlanan "partial tile desteği"
mekanizmasının ağırlık tarafındaki karşılığı, ayrı bir mekanizma icat etmiyor.

**Adres formülü:**
```
addr(bank=r, tile=t, k) = t*K + k
k = c_in*(kH*kW) + kh*kW + kw     // PyTorch native sıra, dönüşümsüz
```
`t` ve `k` tüm 8 bankaya aynı cycle'da aynı adres olarak yayılır — banka seçimi fiziksel
(hangi BRAM bloğu), adres değeri ortak. Tek bir sayaç/FSM 8 bankayı da sürer.

**Dosya formatı:** Katman başına 8 adet `.coe` — Vivado Block Memory Generator'ın native init
formatı, zaten kararlaştırılmış BRAM/ROM ön-yükleme (Roadmap §2) ile birebir uyumlu.

## Alternatifler
- **Tek büyük BRAM + adres hesaplayıcı (bankasız):** 8 array satırının aynı cycle'da 8 farklı
  ağırlığa ihtiyacı var; Zynq-7020'nin dual-port BRAM'i en fazla 2 eşzamanlı erişim verir —
  bankasız şema darboğaz yaratır. Elendi.
- **im2col-tarzı yeniden sıralanmış export:** PyTorch'un native düzenini bozar, Kişi A'ya
  gereksiz dönüşüm yükü ve hata riski ekler; doğrudan convolution zaten seçilmiş olduğu için
  kazanç yok. Elendi.

## Gerekçe
- NVDLA, ağırlıkları çıktı-kanalı gruplarına göre bankluyor (INT8 için 32'li gruplar) —
  "çıktı kanalına göre bankla" prensibi endüstride standart, 8 bankaya (array satır sayısına)
  ölçeklenmiş hâli.
- Gemmini'nin weight-stationary şemasında satırların PE'lere beslenmeden önce transpoze
  edilmesi gerekiyor; output-stationary kararımızda bu problem yok çünkü ağırlık akışı zaten
  satır-bazlı — dönüşümsüz export mümkün.
- FPGA CNN literatüründe çakışmasız erişim için ağırlıkların bağımsız BRAM bankalarına
  dağıtılması standart pratik; arbitrasyon gerektirmeyen tasarımlar tercih ediliyor.

## Sonuçlar
- Kişi A'nın export scriptinde ek dönüşüm adımı yok — doğrudan `tensor.numpy().tobytes()`
  benzeri bir çıktı, 8 dilime bölünüp `.coe`'ye yazılır.
- Kişi B'nin BRAM okuma FSM'i tek adres sayacıyla 8 bankayı paralel sürer, ayrı adresleme
  mantığı gerekmez — kontrol karmaşıklığı düşük kalıyor.
- **RFF'ye genelleme:** `K` ve `out_channels` katman parametresi olarak kalıyor, formül
  değişmiyor — sadece `.coe` dosyaları ve tile sayısı büyür. Şema LeNet-5'e gömülü değil.
- Kaynak: [Architectural Insights: Weight Stationary vs Output Stationary Systolic Arrays](https://ieeexplore.ieee.org/iel8/10892092/10892610/10892683.pdf),
  [Gemmini GitHub](https://github.com/ucb-bar/gemmini),
  [NVDLA In-memory data formats](https://nvdla.org/hw/format.html),
  [NVDLA Unit Description](https://nvdla.org/hw/v1/ias/unit_description.html),
  [An Efficient CNN Accelerator for Low-Cost Edge Systems](https://dl.acm.org/doi/10.1145/3539224)

## Ek madde — 2026-09-25: "dönüşümsüz export" FC1 için geçerli değil

Bu ADR'nin "Hiçbir yeniden sıralama yok" maddesi **conv ağırlıkları için doğru**, FC1 için
değil. Sebebi bu ADR'nin kapsamı dışında bir kararda: aktivasyonlar HWC saklanıyor
([[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]).

Pool2 çıkışı bellekte `[h][w][c]` sırasında; PyTorch `torch.flatten` ise NCHW üzerinden
`[c][h][w]` üretiyor. FC1'in `c_in` indeksi bu iki sıradan hangisine göre tanımlıysa ağırlık
sütunları ona uymak zorunda. Çözüm donanımda değil, Kişi A'nın export script'inde tek satır:

```python
w_fc1 = w_fc1.reshape(120, 16, 5, 5).permute(0, 2, 3, 1).reshape(120, 400)
```

Conv katmanlarının export'u değişmiyor; `bank = c_out mod 8` ve `addr = t*K + k` şeması
aynen geçerli. Bu madde yazılmazsa ağ çalışır ama doğruluk şans seviyesine düşer — donanımda
hiçbir bayrak yanmadığı için Hafta 8'de teşhisi pahalı bir hata sınıfıdır.

> Bu ek madde [[ADR-016 Aktivasyon Tensör Düzeni ve Byte Yerleşimi|ADR-016]]'nın HWC kararına
> bağlıdır; o karar CHW lehine değişirse permütasyon gereksiz hâle gelir.


## Ek madde — 2026-10-07: şema implemente edildi, preload yolu açık kaldı

`rtl/weight_feeder.sv` bu ADR'nin adresleme şemasını birebir uyguluyor: sekiz bağımsız
banka, `bank = c_out mod 8` (banka `r` = engine satırı `r` = `weight_data` lane `r`),
`start`'ta register'lanan `base = tile_idx * k_len`, sonra tüm bankalara aynı cycle'da aynı
adres. Row skew engine'in içinde uygulanıyor, feeder'da değil. Senkron BRAM okuma gecikmesi
iki girişli elastic FIFO ile karşılanıyor; coupled handshake altında (engine iki kenarı
birlikte kabul ediyor, aktivasyon kenarı sürekli aç kalıyor) beat kaybı veya duplikasyonu
yok. `tb_weight_feeder` banka/adres eşlemesini byte byte doğruluyor — beat saymıyor, değer
karşılaştırıyor, çünkü lane'leri ters bağlamak **sessizce transpoze edilmiş convolution**
üretir. Beş mutant denendi (off-by-one sayaç, tile offset'siz base, backpressure altında
düşen valid, prefetch derinliği, bankaların bir lane kaydırılması), beşi de yakalandı.
`tb_conv1_top` aynı şemayı uçtan uca 112 tile boyunca golden'a karşı doğruluyor.

**Ama bu ADR'nin "katman başına 8 adet `.coe`, Block Memory Generator'a yüklenir" maddesi
RTL'de hâlâ yok ve bu artık ölçülmüş bir boşluk.** Bankaların ne initialization'ı ne write
port'u olduğu için sentez onları sabit bellek sayıp **tamamen optimize ediyor**: 2026-10-07
`check_synth_conv1.tcl` koşusunda `u_weights` netlist'te hiç görünmüyor. Simülasyon yeşil,
çünkü testbench bankaları hiyerarşik `$readmemh` ile dolduruyor. Yani donanıma giden yolda
ağırlık diye bir şey yok ve hiçbir test bunu söylemiyordu — `check_synth_conv1.tcl` artık
"ağırlık yolu netlist'te hayatta kaldı mı" kapısını bu yüzden tutuyor.

Kapatma yolu iki seçenek: (a) `.coe` + Block Memory Generator IP'si (bu ADR'nin dediği),
(b) RTL'de `$readmemh` ile BRAM initialization. İkisi de bitstream'e gömülü ağırlık
demek, yani `ADR-012` (çalışma zamanında ağırlık yükleme) kararını değiştirmiyor.

**FC1 uyarısı güncellendi:** yukarıdaki 2026-09-25 ek maddesi FC1 için
`reshape(120,16,5,5).permute(0,2,3,1)` diyor. [[ADR-018 K-Streaming ve Ara Aktivasyon Düzeni|ADR-018]]
2026-10-07'de ara tamponu **padded tile-major** olarak kilitlediği için FC1 fiziksel sırayı
doğrudan okuyacaksa doğru transform `reshape(120,2,8,5,5).permute(0,1,3,4,2)`'dir. Conv
ağırlık export'u değişmiyor; bu ADR'nin `k = ci*(kH*kW) + kh*kW + kw` reduction order'ı ve
"conv'da permütasyon yok" vaadi aynen geçerli.

### 2026-10-07: preload yolu kapandı, bankalar gerçekten BRAM

Üç adımda çözüldü ve her adım ölçüldü:

1. **Write port.** Bankaların ne initialization'ı ne write port'u olduğu için sentez onları
   sabite indirip siliyordu. `weight_feeder`'a ve `conv1_top`'un boundary'sine `wr_*` load
   portu eklendi (`wr_en`, `wr_bank`, `wr_addr`, `wr_data`). Bu aynı zamanda `ADR-012`
   çalışma zamanında ağırlık yükleme kararının kancasıdır.
2. **Write port yetmedi.** Bankalar silinmeyi bıraktı ama Vivado 2025.1 iki boyutlu
   `bank_mem [0:ROWS-1][0:DEPTH-1]` dizisini BRAM inference'a sokmuyor:
   `WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM ... bank_mem_reg with
   524288 registers`. 8 × 8192 × 8 bit = 524.288 bit, xc7z020'de 106.400 FF var.
3. **Banka başına ayrı dizi.** Bellek generate bloğuna taşındı: `g_bank[r].bank_mem
   [0:DEPTH-1]`, banka başına tek boyutlu dizi, senkron okuma, register'lanmış çıkış.
   Ölçüm: **RAMB36 = 16**, yani banka başına tam 2 RAMB36 — bu ADR'nin sekiz fiziksel
   bankasının birebir karşılığı. Regression 10/10 PASS, davranış değişmedi.

Bu yapı ADR-011'in `.coe` + Block Memory Generator kararını **geçersiz kılmıyor**, onun
inferred karşılığı. Sekiz BMG instance'ı tam olarak bu generate bloğunun yerine girer;
adresleme, banking ve port kontratı aynı kalır. Fark yalnız ağırlığın nereden geldiğidir:
şu an `wr_*` portundan (Aşama 1'de testbench, sonra AXI), BMG'de bitstream'den. Bitstream'e
gömülü ağırlık hedefi korunuyorsa ya sekiz `.coe` ile BMG, ya da generate içinde
`$readmemh` initialization eklenmeli; ikisi de bu dosyada tek yere dokunur.

**Testbench'ler artık bankaları hiyerarşik olarak doldurmuyor**, `wr_*` portundan yüklüyor.
İki kazanç: yükleme yolu da test edilmiş oluyor, ve generate dizisine hiyerarşik referans
sabit index gerektirdiği için (XSim: `'bank_mem' is not declared under prefix 'g_bank'`)
döngü değişkeniyle poke etmek zaten mümkün değil.

**FC1 uyarısı güncellendi:** yukarıdaki 2026-09-25 ek maddesi FC1 için
`reshape(120,16,5,5).permute(0,2,3,1)` diyor. [[ADR-018 K-Streaming ve Ara Aktivasyon Düzeni|ADR-018]]
2026-10-07'de ara tamponu **padded tile-major** olarak kilitlediği için FC1 fiziksel sırayı
doğrudan okuyacaksa doğru transform `reshape(120,2,8,5,5).permute(0,1,3,4,2)`'dir. Conv
ağırlık export'u değişmiyor; bu ADR'nin `k = ci*(kH*kW) + kh*kW + kw` reduction order'ı ve
"conv'da permütasyon yok" vaadi aynen geçerli.
