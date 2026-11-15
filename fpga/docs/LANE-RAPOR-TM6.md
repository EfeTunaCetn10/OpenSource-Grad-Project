# LANE-RAPOR-TM6: Mutation Evidence (Faz 6)

## 1. Genel Bakış ve Amaç
Bu rapor, faz6 orkestrasyonunda **Lane TM (Mutation Evidence)** kapsamında hazırlanan mutasyon test altyapısını ve elde edilen tasarım kararlarını belgeler.

Önceki aşamada eklenen üç testbench'in (`tb/tb_fc1_order.sv`, `tb/tb_axis_lane.sv`, `tb/tb_prog_e2e.sv`) varoluş amaçları olan tasarım hatalarını gerçekten yakalayıp yakalamadığını (mutant killing) kanıtlamak üzere bağımsız koşucu betiği oluşturulmuştur:
- **Betik**: [`systolic-array-8x8/sim/mutate_t6.py`](file:///C:/grad-wt/tm6/systolic-array-8x8/sim/mutate_t6.py)
- **Kapsam**: Mevcut hiçbir kaynak dosyası değiştirilmemiş (`Do not edit any existing file` kuralı korunmuştur); her mutant ve kontrol koşusu için `sim/mutbuild_t6/<run_name>/` altında izole scratch ağacı oluşturulup silinmektedir.

---

## 2. Mutant Seçimleri, Anchor'lar ve Hata Modelleme Gerekçeleri

### Mutant M1: `flatten-order`
- **Hedef RTL**: [`systolic-array-8x8/rtl/act_buffer.sv`](file:///C:/grad-wt/tm6/systolic-array-8x8/rtl/act_buffer.sv#L298-L306)
- **Hedef Test**: `tb_fc1_order` (T_FC1_ORDER_001)
- **Seçilen Anchor**:
  ```systemverilog
                else if (rd_t == rd_tiles_m1) begin
                    rd_t <= '0;
                    rd_pix <= rd_pix + 1'b1;
                    rd_addr <= rd_pix + 1'b1;
                end else begin
                    rd_t <= rd_t + 1'b1;
                    rd_addr <= rd_addr + rd_plane;
                end
  ```
- **Uygulanan Mutasyon (Replacement)**:
  ```systemverilog
                else if (rd_t == rd_tiles_m1) begin
                    rd_t <= '0;
                    rd_pix <= rd_pix + 1'b1;
                    rd_addr <= rd_pix + rd_plane;
                end else begin
                    rd_t <= rd_t + 1'b1;
                    rd_addr <= rd_addr + 1'b1;
                end
  ```
- **Hata Modeli ve Mekanizması**:
  `act_buffer.sv`, aktivasyonları tile-major düzende (`mem[tile*plane + pixel]`) saklar; burada `plane = h*w`'dir. Okuma tarafı, window_gen'in beklediği HWC raster akışını üretmek için piksel başına kanal tile'larını (`rd_t`) ardışık olarak okur. Orijinal kodda iç döngü tile adımını (`rd_addr <= rd_addr + rd_plane`), dış döngü ise sonraki piksele geçişi (`rd_addr <= rd_pix + 1'b1`) yapar.
  Mutasyonla bu iki adres adımı terimi yer değiştirir: iç döngüde `1'b1` (aynı düzlemdeki ardışık pikseller), dış döngüde ise `rd_plane` eklenir. Böylece okuma sırası (H, W, C) olmaktan çıkarak düzlem-öncelikli / tile-bazlı bozuk bir sıraya dönüşür.
- **Testbench Tarafından Yakalanma Beklentisi**:
  `tb_fc1_order`, `diag_fc1_order` programını çalıştırır; burada 4 adet one-hot aktivasyon noktası `k=(0, 24, 47, 57)` koordinatlarına yerleştirilmiştir. Tile 1'e düşen aktivasyonlar (kanallar 8..15) bozuk adres sırası nedeniyle FC katmanına yanlış zamanda ve yanlış kanalda ulaşır, matris çarpım sonuçları bozulur ve `prog_replay_env` veri karşılaştırmasında (`m_axis_tdata !== exp_mem`) ilk uyuşmazlıkta `FAIL T_FC1_ORDER_001` vererek mutantı öldürür.

---

### Mutant M2: `s_axis lane reversal`
- **Hedef RTL**: [`systolic-array-8x8/rtl/accel_axis.sv`](file:///C:/grad-wt/tm6/systolic-array-8x8/rtl/accel_axis.sv#L63)
- **Hedef Test**: `tb_axis_lane` (T_AXI_LANE_001)
- **Seçilen Anchor**:
  ```systemverilog
          .s_data(s_axis_tdata), .s_last(s_axis_tlast),
  ```
- **Uygulanan Mutasyon (Replacement)**:
  ```systemverilog
          .s_data({s_axis_tdata[7:0], s_axis_tdata[15:8],
                   s_axis_tdata[23:16], s_axis_tdata[31:24],
                   s_axis_tdata[39:32], s_axis_tdata[47:40],
                   s_axis_tdata[55:48], s_axis_tdata[63:56]}),
          .s_last(s_axis_tlast),
  ```
- **Hata Modeli ve Mekanizması**:
  64-bitlik `s_axis_tdata` veriyolundaki 8 bayt şeridinin sırası accelerator çekirdeğine (`accel_top`) girmeden önce tersine çevrilir (şerit $i \leftrightarrow 7-i$).
- **Testbench Tarafından Yakalanma Beklentisi**:
  `tb_axis_lane`, koordinat kodlu (`64*h + 8*w + c`) 8 kanallı girdiyi birim (identity) evrişim katmanından geçirir. Şeritler girişte ters çevrildiğinde çekirdek 0..7 yerine 7..0 kanallarını işler. Çıkış verisi `exp_mem` ile karşılaştırıldığında beat 0'da hemen veri uyuşmazlığı tespit edilir ve `FAIL T_AXI_LANE_001` ile mutant öldürülür.

---

### Mutant M3: `m_axis lane reversal`
- **Hedef RTL**: [`systolic-array-8x8/rtl/accel_axis.sv`](file:///C:/grad-wt/tm6/systolic-array-8x8/rtl/accel_axis.sv#L49-L67)
- **Hedef Test**: `tb_axis_lane` (T_AXI_LANE_001)
- **Seçilen Anchor**:
  ```systemverilog
      assign m_axis_tkeep = 8'hFF;

      accel_top u_accel_top (
          ... (port bağlantıları) ...
          .m_y_flat(m_axis_tdata),
  ```
- **Uygulanan Mutasyon (Replacement)**:
  ```systemverilog
      assign m_axis_tkeep = 8'hFF;
      logic [63:0] m_axis_tdata_core;
      assign m_axis_tdata = {m_axis_tdata_core[7:0], m_axis_tdata_core[15:8],
                             m_axis_tdata_core[23:16], m_axis_tdata_core[31:24],
                             m_axis_tdata_core[39:32], m_axis_tdata_core[47:40],
                             m_axis_tdata_core[55:48], m_axis_tdata_core[63:56]};

      accel_top u_accel_top (
          ... (port bağlantıları) ...
          .m_y_flat(m_axis_tdata_core),
  ```
- **Hata Modeli ve Mekanizması**:
  Çekirdek çıkışı (`m_y_flat`), ara sinyal `m_axis_tdata_core`'a yönlendirilir ve AXI-Stream çıkış portuna (`m_axis_tdata`) bağlanırken bayt şeritleri tersine çevrilir.
- **Testbench Tarafından Yakalanma Beklentisi**:
  Çekirdek hesaplamayı doğru yapsa dahi çıkış akışındaki şeritlerin ters sırada sunulması nedeniyle `tb_axis_lane` beat 0'da `got !== exp` uyuşmazlığı yakalar ve `FAIL T_AXI_LANE_001` ile mutantı öldürür.

---

## 3. Çalışma Dizinleri ve Vektör Göreli Derinliği (Relative Depth)

`tb_prog_e2e.sv` (ve dolayısıyla `tb_fc1_order.sv` ile `tb_axis_lane.sv`), vektör ve program dosyalarını `$readmemh("../vectors/...", ...)` ve `$fopen("../vectors/...", ...)` çağrılarıyla açar:
- `run_tests.py` akışında simulator çalışma dizini `PROJECT/sim/build` dizinidir; bu dizinden `..` bir üst basamak olan `sim/` dizinine çıkar ve `sim/vectors` yoluna ulaşır.
- `mutate_t6.py` içinde her mutant için oluşturulan scratch ağacı `sim/mutbuild_t6/<run_name>/` altındadır. Derleme ve simülasyon `sim/mutbuild_t6/<run_name>/build` altında çalıştırıldığında simülatörün `../vectors` arayışı `sim/mutbuild_t6/<run_name>/vectors` hedefine yönelir.
- Betik, vektörlerin kırılmasını önlemek için `link_or_copy_vectors()` fonksiyonu ile `sim/vectors` dizinini hem `sim/mutbuild_t6/<run_name>/vectors` hem de `sim/mutbuild_t6/vectors` konumlarına bağlar (NTFS junction veya sembolik bağ; ayrıcalık yoksa kopyalama fallback'i). Bu sayede göreli derinlik birebir korunmuştur.

---

## 4. Çıktı Formatı ve Doğrulama Protokolü

Betik stdout üzerine her koşu için standart bir satır basar:
```text
MUT <name> test=<tb> control|mutant result=<PASS|FAIL> killed=<yes|no|n/a> first=<line>
```
Ardından özet satırı basılır:
```text
MUTATE_T6: killed=<n>/3 controls=<n>/2
```
Ve çıkış kodu yalnızca tüm kontroller PASS ve tüm 3 mutant killed olduğunda `0` olur; aksi halde `1` döner.

---

## 5. Çalıştırmadan Belirlenemeyen Noktalar (Runtime-Determined)

Aşağıdaki unsurlar shell komutu çalıştırılmadığı ve simülasyon orkestratör tarafından tetikleneceği için statik analizle öngörülmüş olup, kesin çıktılar koşu anında netleşecektir:
1. **İlk Hata Satırı İfadesi (`first=<line>`)**:
   `prog_replay_env` içinde `M offset 0 beat <N>` indeksinin tam olarak hangi beat ve cycle'da patlayacağı (LFSR rastgele aralık gecikmelerine bağlı olarak cycle sayısı ve beat sırası).
2. **Derleme ve Simülasyon Süreleri**:
   XSim elaboration ve simulation süreleri donanım yüküne bağlı olarak her mutant için yaklaşık 10-30 saniye aralığında beklenmektedir.
3. **Simülasyon Çıkış Log Detayı**:
   XSim'in `xsim.log` içinde üreteceği webtalk veya versiyon banner satırlarının filtrelenerek doğrudan test failure satırının yakalanması regex (`run_tests.FAIL_RE`) üzerinden garanti altına alınmıştır.
