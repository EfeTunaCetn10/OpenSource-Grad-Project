# FC1 export transform değişti — Kişi A'ya bildirim

## 1. Özet

Dün (2026-10-07) ADR-018 Karar 2 ile ara aktivasyon tensörünün fiziksel layout'u
**padded tile-major** olarak kilitlendi (`addr = (((c_out>>3)*H+h)*W+w)*8+(c_out&7)`),
ve bu kararın FC1'i doğrudan etkileyen bir yan etkisi var: ADR-016'nın sana verdiği FC1
export one-liner'ı (`reshape(120,16,5,5).permute(0,2,3,1)`) artık **yanlış**. FC1 Pool2'nin
çıktısını düzleştirerek okuyor, ve Pool2'nin çıktısı artık plain `[h][w][c]` değil
`[c_tile][h][w][lane]` sırasında bellekte duruyor. Doğru transform aşağıda (bölüm 3).
Eğer FC1 ağırlıklarını zaten eski one-liner'la export ettiysen, yeniden export etmen
gerekiyor — eskisiyle çalışırsa ağ "çalışır görünür" ama FC1'den itibaren çıktı çöp olur,
hiçbir flag yanmaz. **Conv ağırlık export'un değişmiyor** (bölüm 5) — bunu da değiştirme.

## 2. Neden

Karar ve gerekçesinin tam metni:
[[ADR-018 K-Streaming ve Ara Aktivasyon Düzeni#Ek madde — 2026-10-07: Karar 2'nin fiziksel layout'u kilitlendi]].
Kısaca: üç seçenek (dense HWC / padded tile-major / tile-major store + dense gather adapter)
karşılaştırıldı, padded tile-major seçildi çünkü `requant_array`'in ürettiği beat fiziksel
word ile birebir oluyor — sekiz lane tek aligned 64-bit write, bir port, bir cycle. Dense
HWC'de Conv1 beat'i 6 valid byte taşıyor ve başlangıç offset'leri `0,6,4,2` olduğu için
beat'lerin yarısı word crossing yapıyor (worst-case 2 cycle/beat). Ayrıca her physical
row/tile plane 8-byte katı olduğu için [[ADR-006 AXI Stream Paket Semantiği|ADR-006]]'nın
`TKEEP` all-1 değişmezi istisnasız korunuyor (dense HWC'de FC2'nin 84 byte'ı bu değişmezi
kırıyordu). BRAM maliyeti göz ardı edilebilir seviyede (dense'e göre fark 1964 B, 630 KB
bütçenin %2,54'ü). Kararın tam bedel listesi ve geçersiz kılacak kanıt ADR-018'de yazılı,
burada tekrar etmiyorum.

## 3. Doğru transform

```python
w_fc1 = w_fc1.reshape(120, 2, 8, 5, 5).permute(0, 1, 3, 4, 2).reshape(120, 400)
```

`w_fc1` burada PyTorch'un ham native `(120, 400)` ağırlığı — yani senin hâlihazırda
elinde olan, hiç permute edilmemiş hal. Eksen anlamları:

- **120** — FC1 output (değişmiyor, hiçbir eksende permüte edilmiyor).
- **2** — `c_tile` = `c_in >> 3`. Pool2 çıktısı 16 kanal, 8'li iki tile'a bölünüyor.
- **8** — tile içi `lane` = `c_in & 7`. Her tile'ın 8 kanalı.
- **5, 5** — spatial `h`, `w` (Pool2 çıktısı 5×5).

`reshape(120,2,8,5,5)` adımı 400-uzun native eksenini `(c_tile, lane, h, w)` olarak
bölüyor — bunun doğru olmasının sebebi native flatten sırasının zaten `c*25+h*5+w`
olması (`c = c_tile*8+lane`), yani `c_tile*200+lane*25+h*5+w`, ve bu tam olarak
`reshape(120,2,8,5,5)`'in row-major yorumu. `permute(0,1,3,4,2)` sonra `(batch, c_tile,
lane, h, w)`'yi `(batch, c_tile, h, w, lane)`'a taşıyor — bu, fiziksel buffer'ın okuma
sırası. Son `reshape(120,400)` düzleştiriyor: `c_tile*200 + h*40 + w*8 + lane`. Bunun
ADR-018'in adres formülüyle birebir örtüştüğünü aşağıda (bölüm 4) sayısal olarak
doğruladım.

**Eski, artık yanlış olan ADR-016 one-liner'ı (KULLANMA):**

```python
w_fc1 = w_fc1.reshape(120, 16, 5, 5).permute(0, 2, 3, 1).reshape(120, 400)
```

Bu, `(c,h,w)`'yi doğrudan `(h,w,c)`'ye taşıyordu — plain dense HWC `[h][w][c]` sırasına
uygundu. Doğruydu, çünkü ADR-016 yazıldığında ara aktivasyon düzeni henüz "Açık" idi ve
varsayılan dense HWC'ydi. 2026-10-07'de ADR-018 Karar 2 fiziksel layout'u **tile-major**'a
kilitleyince bu one-liner geçersiz kaldı — ADR-016 dosyasının kendisi de bunu şimdi
"Kapandı" bölümünde işaretliyor. Eğer bu notu okumadan önce eski talimatla export ettiysen,
elindeki `.coe`/ağırlık dosyası yanlış sırada; FC1'den itibaren hiçbir katman flag
yakmadan yanlış sonuç üretir.

## 4. Doğrulanabilir örnek

ADR-018'in verdiği örnek: `H=W=5, C=16` için koordinat `c=8, h=1, w=0`. Kendim elle ve
numpy ile ayrı ayrı doğruladım, kopyalamadım:

**Dense HWC adres** (`addr = (h*W+w)*C + c`):
`(1*5+0)*16 + 8 = 80 + 8 = 88` ✓ ADR-018'in verdiği 88 ile eşleşiyor.

**Tile-major adres** (`addr = (((c>>3)*H+h)*W+w)*8 + (c&7)`):
`c_tile = 8>>3 = 1`, `lane = 8&7 = 0`.
`addr = ((1*5+1)*5+0)*8 + 0 = (6*5)*8 = 240` ✓ ADR-018'in verdiği 240 ile eşleşiyor.

Her iki sayı da tuttu — ADR-018'in örneği doğru, kör kopyalama değil.

Ayrıca transform formülünün (bölüm 3) gerçekten bu adrese düştüğünü numpy'da izole
bir deneyle test ettim (`np.arange(400)` ile her eleman kendi native flat-index'ini
taşıyor, sonra iki transform'u uyguladım):

```
orig flat idx (native c,h,w) için c=8,h=1,w=0  : 205
NEW tile-major transform sonrası pozisyon       : 240   (eşleşti)
OLD dense-HWC one-liner sonrası pozisyon         : 88    (eşleşti)
```

Yani yeni transform formülü, `c=8,h=1,w=0` elemanını gerçekten pozisyon 240'a taşıyor —
ADR-018'in iddiası hem formülle hem numpy reshape/permute çalıştırmasıyla doğrulandı.

**Kendi export'unu kontrol etmek için Python snippet'i:**

```python
import numpy as np

def check_fc1_transform(w_fc1_native):
    """w_fc1_native: PyTorch'tan geldiği hâliyle, (120, 400) ham native (c,h,w) flatten."""
    assert w_fc1_native.shape == (120, 400)

    w_tile_major = w_fc1_native.reshape(120, 2, 8, 5, 5).transpose(0, 1, 3, 4, 2).reshape(120, 400)

    # c=8,h=1,w=0 -> native flat idx = c*25+h*5+w = 205, tile-major'da beklenen 240 olmalı
    native_idx = 8 * 25 + 1 * 5 + 0  # 205
    tile_idx = (((8 >> 3) * 5 + 1) * 5 + 0) * 8 + (8 & 7)  # 240

    for out in range(120):
        assert w_tile_major[out, tile_idx] == w_fc1_native[out, native_idx]

    print("FC1 tile-major transform dogrulandi:", native_idx, "->", tile_idx)
    return w_tile_major

# kullanim:
# w_fc1_tile_major = check_fc1_transform(w_fc1_native)
# w_fc1_tile_major.tofile(...) ya da .coe writer'a ver
```

## 5. DEĞİŞMEYEN şeyler — conv ağırlık export'u aynı

**Conv ağırlık export'una dokunma.** [[ADR-011 Ağırlık Bellek Adresleme|ADR-011]]'in
reduction order'ı aynen geçerli:

```
k = c_in*(kH*kW) + kh*kW + kw
```

Bu, conv ağırlıklarının PyTorch native `[out_channels, in_channels, kH, kW]` sırasıyla
**dönüşümsüz** export edildiği anlamına geliyor — hiçbir permute yok. ADR-018'in
2026-09-26 ek maddesi bunu ölçtü: aktivasyonlar HWC saklandığı için `k`'yi spatial-major
yapmanın (`ci` en hızlı değişen eksen) hiçbir kazancı olmadığı kanıtlandı (0 byte, 0 BRAM
portu, 0 stream cycle farkı) — yani kanal-major sıra bir tercih değil, ölçülmüş sonuç.

**Kritik ayrım:** storage layout (ara aktivasyon tensörünün bellekte nasıl durduğu) ile
reduction order (ağırlığın `k` indeksinin hangi sırada arttığı) aynı şey değil. Padded
tile-major kararı yalnız aktivasyon tensörünün *fiziksel adresini* değiştirdi, ağırlığın
`k` sırasını değiştirmedi. FC1'in etkilenmesinin sebebi, FC1'in ara aktivasyon tensörünü
(Pool2 çıktısı) doğrudan düzleştirerek okuması — conv katmanları aktivasyonu `window_gen`
üzerinden logical `(ci,kh,kw)` koordinatlarıyla okuyor, physical adresi görmüyor. Bu farkı
gerekçe gösterip conv ağırlık export'unu da "tutarlılık için" spatial-major'a çevirme —
bu ADR-011'in vaadini kırar ve hiçbir kazanç getirmez.

## 6. Senden ne bekleniyor

1. FC1 ağırlıklarını yukarıdaki (bölüm 3) yeni transform'la export et. Eski one-liner'la
   zaten export ettiysen, yeniden export et.
2. `T_FC1_ORDER_001` regresyonu için one-hot test vektörü hazırla: tek bir ara aktivasyon
   konumu (tile-major physical adreste) 1, gerisi 0; buna karşılık beklenen FC1 çıktı
   vektörü. Bu, transform'un doğru uygulandığını RTL tarafında bağımsız doğrulayacak tek
   test (bölüm 7'de neden henüz kurulamadığı yazılı).
3. ADR-011'in istediği `.coe` formatı için aynı one-hot/order regression verisini üret —
   ağırlık ve aktivasyon tarafı için ayrı ayrı, `.coe`'ye yüklenecek sıranın ADR-018'in
   adres formülüyle birebir örtüştüğünü gösterecek şekilde.

## 7. Blokaj durumu — açıkça yazıyorum, gizlemiyorum

`T_FC1_ORDER_001` test kimliği ADR-018'de tanımlı ama şu an bu repoda **kurulamıyor**:
gerçek bir training checkpoint'i, export script'i ve RTL tarafında bu testi sürecek bir
driver yok. Test senin export'una bağlı — yukarıdaki madde 2'deki one-hot vektör
gelmeden bu test yazılamaz, yazılamadığı için de şu an regresyon setinde yok. Bu, sonradan
"test neden yok" sorusunu önlemek için şimdiden kayda geçiyor: eksik olan RTL değil,
senin teslimin.
