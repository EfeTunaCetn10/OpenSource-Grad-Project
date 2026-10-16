---
title: ADR-011 Preload Karar Memosu — .coe/BMG mi, $readmemh mi
created: 2026-10-08
modified: 2026-10-08
type: decision-memo
status: öneri (karar Emin'de)
tags: [dnn-accelerator, adr, kontrat, rtl, weight-feeder]
---

# ADR-011 Preload Karar Memosu

## Bağlam

[[ADR-011 Ağırlık Bellek Adresleme]]'nin "2026-10-07: preload yolu kapandı" ek maddesi
ağırlık bankalarını gerçek BRAM'e taşıdı (`wr_*` load portu + banka başına tek boyutlu
dizi, ölçüm: RAMB36 = 16) ama ADR'nin yazılı "katman başına 8 adet `.coe`, Block Memory
Generator'a yüklenir" maddesini hâlâ karşılamıyordu. Bu memo o kapanmamış maddeyi
kapatıyor: **(a)** ADR'nin yazılı kararı (`.coe` + BMG IP) ile **(b)** `generate` içinde
`$readmemh` (saf RTL) arasında seçim.

(b) bugün `rtl/weight_feeder.sv`'de çalışır hâlde teslim edildi (`INIT_PREFIX` parametresi,
varsayılan `""` → devre dışı) ve bu makinede ölçüldü. (a) bu makinede **inşa edilmedi** —
aşağıdaki karşılaştırmanın (a) satırları ya genel Vivado/BMG bilgisinden ya da ADR-011'in
kendi metninden geliyor, "doğrulandı" diye işaretlenmiyor.

## Karşılaştırma

| # | Kriter | (a) `.coe` + BMG IP | (b) `$readmemh` (RTL) |
|---|---|---|---|
| 1 | **ADR-011 sadakati** | `+` ADR'nin birebir yazılı metni. | `~` ADR'nin kendi 2026-10-07 ek maddesi (b)'yi zaten eşit kapanış yolu olarak tanımlıyor; (b) seçilirse Karar satırını güncelleyen yeni bir ek madde gerekir — ADR'yi çelmiyor, ADR zaten bunu bekliyordu. |
| 2 | **Vivado 2025.1 akışı** | `-` IP catalog'dan "Block Memory Generator" (Simple/True Dual Port, çünkü `wr_*` ayakta kalıyor) özelleştirilir, `.xci` projeye eklenir, çıkış ürünleri üretilir. Ağırlık her değiştiğinde `.coe` içeriği değişir → Vivado IP'yi "out-of-date" işaretler → `generate_target -force` (veya GUI "Reset/Generate Output Products") **manuel/ekstra bir adım**. | `+` `read_verilog` + `synth_design` her çalıştığında dosyayı olduğu gibi okur; ağırlık değiştiğinde yapılacak ekstra adım yok. Bugün ölçüldü: standalone probe'da `INIT_PREFIX` gerçek `.mem` yoluna ayarlandı, tek komutla sentezlendi, 16 RAMB36. |
| 3 | **XSim uyumluluğu** | `~` BMG çıkış ürünleri XSim için davranışsal model üretir (run_tests.py'nin kendi docstring'i "XSim encrypted Xilinx IP'yi çalıştırabilir" diyor) ama bu üretilmiş kaynaklar `sim/run_tests.py`'nin `sources()` fonksiyonunun topladığı `rtl/*.sv` + `tb/*.sv` glob'unun **dışında** kalır (IP çıkışları tipik olarak `<proj>.srcs/sources_1/ip/<ip>/` altına düşer) — runner'a IP-kaynak ekleme desteği eklenmeden bu akış bugün çalışmaz. **Doğrulanmadı** (BMG IP'si bu makinede kurulmadı). | `+` Doğrulandı: `tb_weight_feeder_init` (bu teslimde eklendi) `wr_en`'i hiç sürmeden, hiyerarşik poke yapmadan, SADECE `INIT_PREFIX` init'iyle 8 bankanın 75 adresini `c1_wbank<r>.mem` ile karşılaştırıp PASS veriyor. `run_tests.py` değişmeden çalıştı. |
| 4 | **Mevcut kazanımın korunması (16 RAMB36)** | `~` 8192×8 bir bankanın BMG'de de 2×RAMB36'ya düşmesi muhtemel (aynı derinlik/genişlik aritmetiği) ama **bu makinede inşa edilip ölçülmedi** — doğrulanmadı. | `+` Doğrulandı iki ayrı yoldan: (i) `vivado/check_synth_conv1.tcl` değişiklik sonrası da RAMB36=16, DSP48=80, WNS=+1.203 ns verdi (bkz. LANE-RAPOR.md) — çünkü `conv1_top` hâlâ `INIT_PREFIX=""` geçiyor, regresyon yok; (ii) `INIT_PREFIX`'i gerçek `c1_wbank` yoluna ayarlayan bağımsız bir `wf_init_wrapper` sentezi (bu makinede, bu oturumda) de RAMB36=16 verdi — yani init KODU çalıştığında da çıkarım bozulmuyor, tahmin değil ölçüm. |
| 5 | **ADR-012 runtime load ile birlikte yaşama** | `-` BMG'de ikinci (yazma) port demek IP'yi "Simple/True Dual Port RAM" olarak özelleştirmek, ve bugünkü `always_ff` içindeki tek-blok "wr_en ise yaz, issue_read ise oku" kalıbını **IP port'larına doğrudan bağlanan** bir örneğe dönüştürmek (banka başına ayrı IP instance, 8 adet) — `weight_feeder.sv`'nin generate bloğu yeniden yazılır. | `+` Zaten çalışıyor, değişmedi: `wr_*` portu `INIT_PREFIX` koduna dokunulmadan aynı `always_ff` içinde kaldı; init bitstream değerini koyar, `wr_*` onu runtime'da ezer. Beş mutant testi (aşağıda) bu ikisinin birbirine karışmadığını gösterdi. |
| 6 | **Versiyon kontrolü** | `-` Net bir yanıtı yok, yeni iş gerektiriyor: `gen_conv1_vectors.py` şu an `.mem` üretiyor, `.coe` üretmiyor — (a) seçilirse bu script'e `.coe` çıkışı eklenmeli (benim dosyam, henüz yapılmadı). Ayrıca commit edilecek şey `.coe` olursa generated-and-gitignored politikası bozulur; edilmezse Vivado tarafında da bir "build başında üret" adımı gerekir — bugün YOK. | `~` Aynı açık soru, ama daha küçük: `sim/vectors/*.mem` hâlâ gitignore'lu/üretilen (`.gitignore:2`, doğrulandı). `sim/run_tests.py`'nin `ensure_vectors()`'ı simülasyon tarafını zaten çözüyor. **Vivado batch/proje akışı tarafında eşdeğer bir "sentezden önce üret" adımı hâlâ yok** — `INIT_PREFIX` gerçek bir yola bağlanırsa (conv1_top entegrasyonu, L1'in işi) `vivado/create_project.tcl` veya eşdeğeri `python model/gen_conv1_vectors.py`'yi senteze girmeden önce çağırmalı. Bu, (b)'nin de kapatmadığı açık bir madde — raporda da işaretlendi. |
| 7 | **Timing** | `~` Teorik olarak fark yok: bir Xilinx RAMB36E1'in `INIT_xx` bitstream öznitelikleri hem BMG'den hem `$readmemh`'ten aynı mekanizmayla (statik konfigürasyon biti) üretilir, mantık/zamanlama yoluna girmez. Bu makinede BMG inşa edilmediği için iki netlist'in `INIT_xx` dizgelerini bit bit karşılaştırmadım — **doğrulanmadı**, genel Xilinx davranışına dayanıyor. | `+` Ölçüldü, fark yok: `check_synth_conv1.tcl` WNS değişmedi (+1,203 ns, ADR-011'in 2026-10-07 ölçümüyle aynı), standalone probe (`INIT_PREFIX` gerçek yolla) WNS=+5,052 ns verdi (izole modül, farklı bağlam, direkt kıyaslanamaz ama negatif slack yok). Init kodu `initial` bloğunda, hiçbir `always_ff`/kombinasyonel yola girmiyor — kritik yolu etkileme mekanizması yok. |
| 8 | **Katman büyümesi (conv2/FC1/FC2)** | `-` ADR-011 "şema değişmiyor, sadece `.coe` ve tile sayısı büyür" diyor ama her yeni katman yeni bir IP instance seti (katman başına 8 BMG örneği) ve her ağırlık güncellemesinde o setin tamamının yeniden üretilmesi demek — IP yönetimi katman sayısıyla çarpılıyor. | `+` Yalnızca yeni bir `weight_feederlayer_N #(.INIT_PREFIX("...wbank"))` örneği ve yeni `.mem` dosya adı; aynı `generate` kodu, aynı toolchain, IP catalog'a hiç dokunulmuyor. |
| 9 | **Bu makinedeki tekrarlanabilirlik (temiz clone → bitstream)** | `-` Bugün: (i) `.coe` üretimi script'te yok — yazılmalı, (ii) IP catalog'da BMG özelleştirilmeli (GUI veya Tcl, ilk kurulum manuel), (iii) `generate_target`, (iv) senteze devam. En az 3 yeni el adımı, hiçbiri bugün repo'da yok. | `~` Bugün: `python model/gen_conv1_vectors.py` (veya `sim/run_tests.py`'nin otomatik tetiklediği hâli) → senteze devam. Ama madde 6'daki Vivado-tarafı "sentezden önce üret" adımı hâlâ eksik olduğu için "tamamen tek komut" değil — eksik parça küçük (bir `exec`/`source` satırı) ama bugün yok, bu yüzden tam puan değil. |

## Öneri

**(b) — `$readmemh` init — önerilen yol.** Gerekçe, kriter bazında değil, tek cümlede:
ADR-011'in kendi metni (b)'yi zaten eşit bir kapanış yolu olarak tanımlamışken, (a) bu
makinede ölçülmemiş en az üç yeni toolchain adımı (IP özelleştirme, `.coe` üretimi,
run_tests.py'ye IP-kaynak desteği) gerektiriyor, (b) ise bugün sıfır yeni adımla,
ölçülmüş 16 RAMB36 / +1,203 ns WNS / 11-11 regresyon ile teslim edildi.

Önerinin sınırı: (a)'yı "yanlış" ilan etmiyorum, "bu projede bugün gerekçesiz ek risk"
diyorum. BMG'nin gerçek bir üstünlük sunduğu tek durum — IP'nin kendi ECC/ikinci
bağımsız gerçek dual-port erişim gibi özellikleri gerekirse, ya da ağırlık IP'si proje
dışına dağıtılacaksa (şifreli netlist) — bu projede yok: tek FPGA'ya gömülü bitstream,
tek kullanıcı, tez teslimi.

**Eğer Emin (a)'yı seçerse** açık kalan iş: `model/gen_conv1_vectors.py`'ye `.coe` çıkışı
eklemek, BMG IP'yi Tcl ile (GUI'siz, script'lenebilir) özelleştirip projeye eklemek,
`sim/run_tests.py`'nin `sources()`'ına IP sim-model yolu eklemek, ve weight_feeder'ın
generate bloğunu IP-instance'a bağlayacak şekilde yeniden yazmak — bunların hiçbiri bugün
yapılmadı.

**Eğer Emin (b)'yi seçerse** açık kalan iş: ADR-011'e "(b) seçildi" diyen bir ek madde
(Karar satırını güncelleyen), `conv1_top.sv`'nin (L1'in dosyası) `INIT_PREFIX`'i gerçek
`c1_wbank` yoluna bağlaması, ve madde 6/9'daki Vivado-tarafı "sentezden önce üret" adımının
`vivado/create_project.tcl`'ye (veya CI script'ine) eklenmesi.

Hiçbir durumda `wr_*` portu kaldırılmıyor — ADR-012 bağımsız kalıyor.
