/mo## ARM Tabanlı FPGA-SoC Üzerinde Gerçeklenen Özel DNN Accelerator Mimarisi

Proje Özeti (Abstract)

## Kısa Özet

Bu bitirme projesi, ARM tabanlı bir FPGA-SoC (Zynq-7000 ailesi, PYNQ-Z2 development board) üzerinde gerçeklenen, özgün bir DNN (Deep Neural Network) donanım hızlandırıcısının (AI accelerator) tasarımını, doğrulanmasını ve değerlendirilmesini kapsamaktadır. Genel amaçlı işlemcilerin Von Neumann bottleneck (bellek darboğazı) nedeniyle derin öğrenme iş yüklerinde — özellikle yoğun matris çarpımı (matrix multiplication) işlemlerinde — verimsiz kaldığı gözleminden hareketle, proje kapsamında systolic array tabanlı, INT8 fixed-pointhassasiyetinde çalışan özelleştirilmiş bir Processing Element (PE) dizisi RTL (Register-Transfer Level) düzeyinde tasarlanmakta; bu dizi AXI4-Lite ve AXI4-Stream arayüzleri üzerinden ARM Cortex-A9 tabanlı Processing System'e (PS) entegre edilmektedir. Proje, riski kontrollü biçimde yönetmek amacıyla üç aşamalı (gated) bir çerçevede ilerlemektedir: (1) basit ölçekli bir sınıflandırma görevi üzerinden uçtan uca sistem tasarımının simülasyon ortamında doğrulanması, (2) başarılı simülasyon sonrası tasarımın fiziksel karta implementasyonu, (3) sistemin RF Fingerprint (RFF) sınıflandırma görevine uyarlanması. Projenin nihai hedefi bu üçüncü aşamadır; ilk aşamadaki görüntü sınıflandırma pipeline'ı, düşük performanslı bir kanıt-of-concept olarak değil, RFF hedefinin üzerine güvenle inşa edilebilecek gerçek anlamda işlevsel ve verimli bir teknik temel olarak geliştirilmektedir. Tasarımın performans ve enerji verimliliği, ticari bir edge AI platformu olan NVIDIA Jetson'ın Deep Learning Accelerator (DLA) birimiyle karşılaştırmalı olarak nicel şekilde değerlendirilecektir.

**Kilitlenen tasarım parametreleri (28 Ağustos 2026):** 8×8 (64 PE) output-stationary systolic array; simetrik INT8 aritmetik, per-output-channel ölçekleme, INT32 accumulator; 32×32 RGB girdi; tek clock domain, 100 MHz hedef; AXI4-Stream (64-bit) veri yolu üzerinde Simple-mode AXI DMA, AXI4-Lite kontrol; ağırlıklar 8 BRAM bankasına önceden yüklenir. Kararların tamamı gerekçeleri ve elenen alternatifleriyle birlikte ADR (Architecture Decision Record) olarak belgelenmiştir.

## 1. Problem Tanımı ve Motivasyon

Derin öğrenme modellerinin çıkarım (inference) aşaması, büyük ölçüde matris çarpımı ve convolution işlemlerinden oluşur; bu işlemler doğası gereği yüksek düzeyde paralelleştirilebilir. Buna karşın genel amaçlı bir CPU, sıralı (sequential) işlem modeli ve Von Neumann mimarisinin getirdiği bellek darboğazı nedeniyle bu iş yükü sınıfında verimsiz kalmaktadır. Bu gözlem, endüstride domain-specific architecture (DSA) yaklaşımının — genel amaçlılıktan ödün verip donanımı belirli bir işlem sınıfına özel olarak tasarlama fikrinin — yaygınlaşmasına yol açmıştır (GPU, TPU, NPU, FPGA tabanlı hızlandırıcılar). Proje, bu


yaklaşımı akademik/eğitsel ölçekte, sıfırdan bir donanım tasarımı yaparak somutlaştırmayı hedeflemektedir.

## 2. Projenin Amacı ve Kapsamı

Projenin nihai hedefi, RF Fingerprint (RFF) sınıflandırmasını gerçekleştirebilen, gerçek sektörel değeri olan bir donanım hızlandırıcısı ortaya koymaktır. Bu hedefe ulaşmak için gereken teknik temel — 2D görüntü verisini alıp donanım üzerinde hızlandırılmış şekilde sınıflandırabilen, uçtan uca çalışan bir SoC pipeline'ı — projenin ilk aşamasında (Aşama 1) inşa edilmektedir.

Kapsam bilinçli olarak dar ve derin tutulmuştur: tek, sabit boyutlu bir ağ mimarisi (LeNet-5) ve tek bir precision (INT8) üzerinden ilerlenmekte; genel amaçlı, her ağı çalıştırabilecek bir sistem hedeflenmemektedir. Bu daralmanın amacı eforun dağılmasını önleyip kaynakları tek bir pipeline'da yoğunlaştırmaktır — amaç minimal bir kanıt sunmak değildir; tam tersine, düşük performanslı, kullanışsız veya verimsiz bir tasarım kabul edilmemekte, nihai hedefin (RFF) üzerine güvenle inşa edilebilecek, gerçek anlamda işlevsel, kullanılabilir hızda ve verimlilikte çalışan bir donanım temeli hedeflenmektedir. Kapsamın darlığı, iş kalitesinden ödün vermek için değil, o kaliteyi tek bir pipeline'a odaklayabilmek için tercih edilmiştir.

## 3. Teknik Yaklaşım ve Mimari

## 3.1 Hesaplama Çekirdeği

Sistemin merkezinde, systolic array mimarisiyle düzenlenmiş bir PE (Processing Element) dizisi bulunmaktadır. Her PE, INT8 hassasiyetinde bir çarpma-toplama (MAC) birimidir ve donanımın DSP48 slice kaynaklarına sentez aracı tarafından otomatik olarak haritalanacak şekilde generic Verilog ile yazılmaktadır (7-series'e özel primitive'ler elle instantiate edilmemektedir — bu, ileride farklı bir FPGA ailesine geçiş gerekirse taşınabilirliği garanti eder). Bu tercih, tek bir DSP48E1 slice'ına iki INT8 çarpma paketleme tekniğinden bilinçli olarak feragat etmek anlamına gelmektedir; dizi boyutu 64 DSP48E1 ile mevcut 220'lik bütçenin yalnızca %29'unu kullandığından bu feragatin pratik bir maliyeti bulunmamaktadır.

## 3.2 Dataflow Stratejisi

PE dizisi, **output-stationary** dataflow ile çalışacak şekilde tasarlanmaktadır: her PE, bir çıktı elemanının tüm MAC reduction'ını (K adet MAC) yerel olarak biriktirir; partial sum PE dışına çıkmaz. Bu seçim, weight-stationary alternatifine kıyasla PE'ler arası partial sum arayüzü gerektirmediği için doğrulama karmaşıklığını azaltmakta ve projenin sınırlı zaman çizelgesinde fonksiyonel doğruluğa ulaşma riskini düşürmektedir. Bu karar, ekip içinde erken aşamada kilitlenen bir "kontrat noktası" niteliğindedir. INT32 accumulator ve bias addition modulo `2^32` wrap yapar; wrap addition associative olduğu için integer golden model aynı MAC sırasını izlemek zorunda değildir. Her output için bias, rounding ve INT8 saturation kuralı birebir aynı olmalıdır.

## 3.3 Sistem Entegrasyonu


PE dizisi, AXI4-Lite (kontrol/register erişimi) ve AXI4-Stream (veri akışı) arayüzleriyle sarmalanarak bir DMAdenetleyicisi üzerinden ARM Cortex-A9 tabanlı Processing System (PS) bloğuna bağlanmaktadır. Vivado IP Integrator ortamında, Zynq PS bloğu, DMA IP'si ve özel accelerator IP'si tek bir Block Design içinde birleştirilmektedir.

## 3.4 Quantization

Model, PyTorch'ta eğitildikten sonra post-training quantization (PTQ) ile INT8'e indirgenmekte; doğruluk kaybı kabul edilemez düzeydeyse quantization-aware training (QAT)'e geçilmesi planlanmaktadır. Sayısal format ekip içinde netleştirilen bir diğer kontrat noktasıdır ve kilitlenmiştir: ağırlık ve aktivasyonlar simetrik (zero-point = 0) signed INT8; ağırlık scale'i per-output-channel, aktivasyon scale'i per-tensor; accumulator ve bias signed INT32, MAC ve bias addition wrap modulo `2^32`; requantization signed 64-bit product + rounding offset + arithmetic shift ile yapılır (`half_ulp = n == 0 ? 0 : 2^(n-1)`, `y_raw = (acc·M0 + half_ulp) >>> n`). Rounding round-half-up, INT8 saturation requant output'undadır. Python golden model ve Verilog RTL aynı arithmetic shift kuralını paylaşır.

## 4. Aşamalı Hedef Çerçevesi (Gated Roadmap)

Proje riski, doğrusal değil koşullu (gated) bir ilerleme modeliyle yönetilmektedir — her aşama, bir öncekinin başarıyla tamamlanmasına bağlıdır:

| Aşama | Kapsam | Takvim / Durum |
| --- | --- | --- |
| **Aşama 1** | Basit ölçekli bir sınıflandırma görevi (böcek türü sınıflandırması) için uçtan uca SoC tasarımı — RTL, DMA, AXI entegrasyonu, quantization ve ML eğitim süreçleri dahil, tamamen simülasyon ortamında (Vivado XSim + AXI Verification IP), fiziksel karta implementasyon yapılmadan | **En geç 30 Eylül 2026.** Devam ediyor |
| **Aşama 2** | Aşama 1'de doğrulanan tasarımın fiziksel PYNQ-Z2 kartına implementasyonu: yer-yerleştirme, zamanlama kapanışı (timing closure), optimizasyon ve donanım üzerinde doğrulama | **En geç 31 Aralık 2026.** Aşama 1 tamamlanınca başlar |
| **Aşama 3** | Sistemin RF Fingerprint sınıflandırma görevine uyarlanması. RF sinyalinin ön işlenmesi ve ilgili ML süreçleri proje danışmanının uzmanlık alanı kapsamında sağlanacak; ekibin sorumluluğu donanım/accelerator tarafında sabit kalmaktadır | **En geç 31 Aralık 2026.** Aşama 2 ile örtüşük yürütülebilir |

## 5. Ekip Yapısı ve Görev Dağılımı

Proje iki kişilik bir ekip tarafından paralel olarak yürütülmektedir:

- Kişi A — ML & Doğrulama: Model eğitimi (PyTorch), quantization, ağırlık export, donanımın üreteceği çıktıyı doğrulamak için kullanılan Python tabanlı golden reference model

- Kişi B — RTL & Entegrasyon: PE/systolic array tasarımı, AXI/DMA arayüzü, PS entegrasyonu, simülasyon ortamının kurulması


İki hattın bağımsız ilerleyebilmesi, aralarında erken ve net şekilde kilitlenen üç kontrat noktasına dayanmaktadır: (1) fixed-point format, (2) dataflow hesaplama sırası, (3) ağırlık bellek düzeni/adresleme şeması. Üçü de 28 Ağustos 2026 itibarıyla karara bağlanmış ve belgelenmiştir.

## 6. Değerlendirme Metodolojisi

Tasarımın başarısı iki eksende ölçülecektir:

- Fonksiyonel doğruluk: cocotb tabanlı bir testbench ile, Kişi A'nın Python'da ürettiği golden reference model çıktısı, Kişi B'nin RTL simülasyon çıktısıyla otomatik olarak karşılaştırılacaktır.

- Performans/verimlilik karşılaştırması: Tasarımın latency, throughput ve enerji verimliliği (TOPS/W), aynı sınıflandırma görevini çalıştıran bir NVIDIA Jetson platformunun DLA (Deep Learning Accelerator) birimiyle nicel olarak kıyaslanacaktır. Değerlendirmenin amacı ticari bir ürünü "geçmek" değil, aradaki farkı ölçüp mimari nedenleriyle (ASIC/FPGA verimlilik farkı, process node, tasarım optimizasyon seviyesi) açıklamaktır — bu yaklaşım literatürdeki accelerator araştırmalarının standart karşılaştırma pratiğiyle örtüşmektedir.

## 7. Referans Mimariler ve Kullanılan Araçlar

İncelenen referans donanım mimarileri: NVDLA (NVIDIA Deep Learning Accelerator, açık kaynak, saf Verilog), Gemmini (UC Berkeley, Chisel tabanlı systolic array generator), Eyeriss (MIT, row-stationary dataflow), Google TPU (Jouppi et al., 2017).

Tasarım ve doğrulama araçları: Vivado (RTL sentezi, IP Integrator, XSim simülasyonu), AXI Verification IP (yazılım/gerçek ARM olmadan AXI transaction'larını simüle etmek için), PyTorch (model eğitimi ve quantization), cocotb (Python tabanlı testbench çerçevesi).

Temel teorik kaynaklar: Sze, Chen, Yang, Emer — "Efficient Processing of Deep Neural Networks: A Tutorial and Survey"; Jouppi et al. — "In-Datacenter Performance Analysis of a Tensor Processing Unit"; LeCun et al. — "Gradient-Based Learning Applied to Document Recognition" (LeNet-5).

## 8. Beklenen Katkı

Proje sonunda, 
(i) çalışır ve doğrulanmış bir özgün DNN accelerator RTL tasarımı
(ii) bu tasarımın ticari bir edge AI platformuyla nicel karşılaştırmasını içeren bir performans/verimlilik analizi
(iii) Aşama 1'de geliştirilen sınıflandırma pipeline'ının gerçek ve sektöre yönelik bir probleme (RF Fingerprint sınıflandırma) uygulanarak somut bir çözüme dönüştürülmüş olması ortaya konulmuş olacaktır.

RFF uyarlamasının hangi veri temsili üzerinden yapılacağı — RF sinyalinin FFT ile 2D spectrogram görüntüsüne dönüştürülmesi ya da ham I/Q dizisi üzerinde 1D convolution — Aşama 3'te, danışmanın yönlendirmesi ve doğruluk ölçümleri ışığında kararlaştırılacaktır; literatürde her iki yaklaşım da kullanılmaktadır. Bu belirsizlik donanım tasarımını bağlamamaktadır, çünkü kilitlenen kontratlar iki temsili de karşılamaktadır: 2×512 boyutlu bir I/Q dilimi ile 32×32 tek kanallı bir görüntü aynı 1024 baytlık AXI4-Stream çerçevesine karşılık gelmekte, 1D convolution ise 2D convolution'ın `kH = 1` özel hâli olarak aynı ağırlık adresleme formülüne ve aynı line buffer yapısına oturmaktadır.

Projenin katkısı bu nedenle mimarinin soyut bir "genellik" sergilemesinden değil, aynı hesaplama çekirdeğinin farklı bir veri kaynağına (RF sinyali) — temsil biçiminden bağımsız olarak — uygulanabilir olmasından kaynaklanmaktadır.
