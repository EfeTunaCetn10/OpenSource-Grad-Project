/# Aşama 1 — Ağustos-Eylül Ana Plan (Kişi A + Kişi B)
### 5 Ağustos – 30 Eylül 2026 | Board: PYNQ-Z2 (elinize Eylül sonunda ulaşacak, bu dönemi etkilemiyor — Aşama 1 zaten tamamen simülasyon)

---

## 1. Roller ve Hedef

- **Kişi A — ML & Doğrulama:** Model eğitimi (PyTorch), quantization, ağırlık export, golden reference model
- **Kişi B — RTL & Entegrasyon:** PE/systolic array, AXI/DMA arayüzü, PS entegrasyonu, simülasyon ortamı

**Eylül sonu "bitti" tanımı:** PE array + AXI4-Lite/Stream arayüzü + DMA + Zynq7 PS bloğu, AXI VIP üzerinden uçtan uca simülasyonda çalışıyor; Kişi A'nın gerçek quantize ağırlıkları ve golden reference model'i bu sisteme entegre edilmiş ve cocotb testbench'i otomatik doğrulama yapıyor. Bu noktada Aşama 1 tamamlanmış olur.

---

## 2. Ortak Zorunlu Kaynaklar (ikisi de bunları bilmeli)

| Kaynak | Neden |
|---|---|
| Sze, Chen, Yang, Emer — *"Efficient Processing of Deep Neural Networks: A Tutorial and Survey"* (arxiv.org/pdf/1703.09039) | Ortak terminoloji ve taksonomi — ikinizin de konuşurken aynı kelimeleri aynı anlamda kullanması için |
| **[VİDEO]** Vivienne Sze, NeurIPS 2019 Invited Tutorial — *"Efficient Processing of Deep Neural Networks: from Algorithms to Hardware Architectures"* (slides + video: eems.mit.edu/publications/tutorials üzerinden SlidesLive) | Algoritmadan donanıma tüm zinciri tek oturumda gösteren, izlenebilir tek video kaynağı — Hafta 1'de ikiniz birlikte izleyin |
| Jouppi et al. — *"In-Datacenter Performance Analysis of a Tensor Processing Unit"* (arxiv.org/abs/1704.04760) | Systolic array + roofline model'i somut bir örnekle birleştiriyor |

---

## 3. Haftalık Detaylı Plan

### Hafta 1 — 5-11 Ağustos
| | Görev | Must Kaynak |
|---|---|---|
| **Kişi A** | PyTorch temelleri | "60 Minute Blitz" (docs.pytorch.org/tutorials) |
| **Kişi B** | HDLBits pratiği başlangıç + FPGA kaynak kavramları (LUT/DSP/BRAM) | hdlbits.01xz.net |
| **Ortak** | Proje önerisi yazımı · kapsam kesinleştirme (veri seti, ağ boyutu = LeNet-5, precision = INT8) · "emulatör" tanımını hocayla teyit (AXI VIP tabanlı testbench, tam ARM emülasyonu değil) · yukarıdaki NeurIPS videosunu birlikte izleyin | — |

### Hafta 2 — 12-18 Ağustos
| | Görev | Must Kaynak |
|---|---|---|
| **Kişi A** | "Training a Classifier" (CIFAR-10) tutorial'ını tamamla | PyTorch resmi tutorial (docs.pytorch.org/tutorials) |
| **Kişi B** | HDLBits devam + fixed-point/INT8 aritmetiği + DSP48 mimarisi | DSP48E1 Slice User Guide, Xilinx **UG479** |
| **Ortak — KRİTİK KARAR ✅** | **Fixed-point format kontratı KİLİTLENDİ (28 Ağu):** simetrik INT8, per-output-channel ağırlık ölçeği, INT32 acc, requant `(acc·M0 + 2^(n-1)) >>> n`, round-half-up. Tam metin: [[ADR-003 INT8 Fixed-Point Formatı]] | PyTorch Quantization docs, "Quantization Basics" bölümü |

### Hafta 3 — 19-25 Ağustos
| | Görev | Must Kaynak |
|---|---|---|
| **Kişi A** | LeNet-5'i PyTorch'ta sıfırdan implement et, MNIST'te eğit | LeCun, Bottou, Bengio, Haffner — *"Gradient-Based Learning Applied to Document Recognition"* (1998) — LeNet-5'in orijinal makalesi |
| **Kişi B** | NVDLA repo incele + TPU makalesini bitir | github.com/nvdla/hw (RTL klasörü, saf Verilog) |
| **Ortak** | Yok, tam paralel | — |

### Hafta 4 — 26 Ağustos-1 Eylül
| | Görev | Must Kaynak |
|---|---|---|
| **Kişi A** | Hedef veri setine (böcek) geçiş — veri hazırlama, augmentation. **Girdi 32×32 RGB** ([[ADR-002 CNN Topolojisi ve Dataset]]), normalizasyon katsayıları kanal başına ayrı | — |
| **Kişi B** | Tek PE (INT8 MAC) tasarımı + testbench + simülasyon (Hafta 2'deki format kontratını kullanarak) | — |
| **Ortak checkpoint (hafta sonu)** | Kısa senkronizasyon: A ilk model sonuçlarını, B tek PE simülasyonunu gösterir; format kontratının pratikte tutup tutmadığı kontrol edilir | — |

### Hafta 5 — 2-8 Eylül
| | Görev | Must Kaynak |
|---|---|---|
| **Kişi A** | Model eğitimini tamamla, doğruluk/confusion matrix analizi | — |
| **Kişi B** | Tek PE'yi NxN systolic array'e ölçekle, kontrol FSM tasarla | — |
| **Ortak — B'DEN A'YA ÖĞRETME** | Dataflow **output-stationary** olarak seçildi ([[ADR-004 Systolic Array Boyutu]], 8×8/64 PE). B bunu A'ya anlatmalı — A'nın golden model'i **aynı hesaplama sırasını** (ya da matematiksel eşdeğerini) izlemezse karşılaştırma anlamsızlaşır | — |

### Hafta 6 — 9-15 Eylül
| | Görev | Must Kaynak |
|---|---|---|
| **Kişi A** | Post-training quantization (PTQ), doğruluk kaybını ölç | PyTorch Quantization Recipe (docs.pytorch.org) |
| **Kişi B** | PE array'i test vektörleriyle doğrula + AXI4-Lite/Stream protokolünü öğren | **AXI Basics 1** (Introduction to AXI) + **AXI Basics 2-3** (AXI VIP ile simülasyon) — adaptivesupport.amd.com |
| **Ortak** | Yok, paralel | — |

### Hafta 7 — 16-22 Eylül
| | Görev | Must Kaynak |
|---|---|---|
| **Kişi A** | Quantize ağırlıkları export formatına (.coe/.bin) çevir, golden reference model'i yazmaya başla | — |
| **Kişi B** | PE array'i AXI4-Lite/Stream ile sarmalayan arayüz + AXI VIP testbench + DMA IP inceleme | **AXI Basics 5** (custom IP) + Xilinx **Embedded Design Tutorials** (xilinx.github.io/Embedded-Design-Tutorials) |
| **Ortak — B'DEN A'YA ÖĞRETME ✅** | Ağırlık bellek düzeni **KİLİTLENDİ (28 Ağu):** PyTorch native `[out,in,kH,kW]` sırası, dönüşümsüz; `bank = c_out mod 8`, adres `t*K + k`. Tam metin: [[ADR-011 Ağırlık Bellek Adresleme]]. B yine de şemayı A'ya anlatmalı | — |

### Hafta 8 — 23-30 Eylül
| | Görev | Must Kaynak |
|---|---|---|
| **Kişi A** | Golden reference model'i tamamla, test vektörleri üret | — |
| **Kişi B** | Zynq7 PS bloğunu Block Design'a ekle/yapılandır, DMA + accelerator'a bağla, uçtan uca simülasyon | **AXI Basics 6-7** (PS bağlantısı) + **xup_high_level_synthesis_design_flow** (github.com/Xilinx/xup_high_level_synthesis_design_flow — PYNQ-Z2'ye özel) |
| **Ortak — BÜYÜK ENTEGRASYON** | ⚠️ **Düzeltildi:** cocotb ile AXI VIP aynı simülatörde çalışmıyor ([[ADR-009 Doğrulama Ortamı]]). Uçtan uca sistem simülasyonu **XSim + SystemVerilog** testbench'te; A'nın golden model karşılaştırması **dosya üzerinden offline** (A vektörü dosyaya yazar → RTL `$readmemh` okur, çıktıyı dosyaya döker → Python karşılaştırır). Hafta sonunda: PE array + AXI + DMA + PS, gerçek quantize ağırlıklarla simülasyonda çalışıyor olmalı | — |

---

## 4. Kritik Kontrat Noktaları — özet

Bu üç karar, iki kişinin bağımsız çalışabilmesi için erken ve net kilitlenmeliydi. **Üçü de
28 Ağustos 2026 itibarıyla kilitlendi:**

1. ✅ **Fixed-point format** → [[ADR-003 INT8 Fixed-Point Formatı]] — simetrik INT8,
   per-output-channel ölçek, round-half-up requantization
2. ✅ **Dataflow sırası** → [[ADR-004 Systolic Array Boyutu]] — output-stationary, 8×8 (64 PE)
3. ✅ **Ağırlık bellek düzeni/adresleme** → [[ADR-011 Ağırlık Bellek Adresleme]] — PyTorch
   native layout, 8 banka (`c_out mod 8`)

Kalan tüm tasarım kararları da karara bağlandı: [[ADR-001 Board ve Araç Sürümü]],
[[ADR-002 CNN Topolojisi ve Dataset]], [[ADR-005 Direct Convolution]],
[[ADR-006 AXI Stream Paket Semantiği]], [[ADR-007 DMA Modu]],
[[ADR-008 Clock Domain Stratejisi]], [[ADR-009 Doğrulama Ortamı]]. Aşama 2'ye bırakılanlar:
`ADR-012` (runtime ağırlık yükleme), `ADR-013` (skip connection desteği).

> [!note] Kilitlenme sonrası
> Bunlar netleşmeden ilerlenseydi Hafta 8'deki entegrasyon büyük olasılıkla uyuşmazlık çıkaracaktı. Kontratlar kilitlendiğine göre sıradaki iş **`T_NUM_REQ_001`**: requantizer'ın bit-exact testi, kasıtlı tie vektörleriyle ([[ADR-003 INT8 Fixed-Point Formatı]]). Array'den önce yazılabilir ve sözleşmenin en zor maddesini şimdiden kanıtlar.

---

## 5. Tam Kaynak Listesi (referans için tek liste)

**Kişi A:**
- PyTorch "60 Minute Blitz" — docs.pytorch.org/tutorials
- PyTorch "Training a Classifier" (CIFAR-10)
- PyTorch Quantization docs/recipe
- LeCun et al. 1998, LeNet-5 orijinal makalesi

**Kişi B:**
- HDLBits — hdlbits.01xz.net
- DSP48E1 Slice User Guide (UG479)
- NVDLA repo — github.com/nvdla/hw
- TPU paper — arxiv.org/abs/1704.04760
- AXI Basics serisi (1, 2, 3, 5, 6, 7) — adaptivesupport.amd.com
- Xilinx Embedded Design Tutorials — xilinx.github.io/Embedded-Design-Tutorials
- xup_high_level_synthesis_design_flow — github.com/Xilinx/xup_high_level_synthesis_design_flow

**Ortak:**
- Sze et al. 2017 survey — arxiv.org/pdf/1703.09039
- Vivienne Sze NeurIPS 2019 tutorial (video) — eems.mit.edu/publications/tutorials
- TPU paper (ikisi için de faydalı)

---

## 6. Board Notu

PYNQ-Z2 Eylül sonunda elinize ulaşacak — bu, yukarıdaki plandan hiçbir şeyi değiştirmiyor, çünkü Aşama 1 zaten tamamen simülasyon (AXI VIP ile). Board'un gelişi, Ekim'de başlayacak Aşama 2'nin (fiziksel implementasyon) girdisi olur. B'nin yazdığı RTL, generic/portable kalacağı için (7-series'e özel primitive'ler elle instantiate edilmeyecek) board fiilen elinize geçtiğinde ek bir uyum çalışması gerektirmeden devam edilebilir.
