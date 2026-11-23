# PortraitPad

Membuat iPad yang tersambung lewat **Sidecar** tampil **portrait (tegak)** di Mac, lengkap dengan
input sentuh. Sidecar bawaan Apple tidak bisa diputar; PortraitPad menggantikan BetterDisplay untuk
satu tugas ini saja, tanpa aplikasi berbayar.

Diuji di macOS 27.0.1, MacBook Air M1, iPad Pro 12.9" (M1).

## Versi

- **`main`**: portrait, ketuk = klik, scroll 1 jari, dan swipe 2 jari untuk pindah Space.
- **Tag `v1-konservatif`**: versi yang lebih konservatif dan paling aman, **tanpa** swipe 2 jari
  (tidak ada tombol Ctrl yang dikirim). Kalau swipe menimbulkan masalah, kembali ke versi ini:

  ```bash
  git checkout v1-konservatif && ./build.sh   # lalu pasang ulang seperti di bawah
  ```

## Cara kerja

```
layar virtual "PortraitPad" 984×1312 pt, HiDPI, 60 Hz   (CGVirtualDisplay, API privat)
  → direkam dengan ScreenCaptureKit (frame IOSurface, hanya saat isi layar berubah)
  → ditempel ke CALayer yang diputar +90° di jendela yang menutupi layar Sidecar
```

Tidak ada salinan piksel lewat CPU. Saat diam sekitar 0,5–0,7% CPU dan ~15–30 MB RAM.

- Menyala/mati otomatis saat Sidecar tersambung/putus.
- Posisi layar iPad terakhir (System Settings ▸ Displays ▸ Arrange) diingat dan dipakai lagi.
- Layar Sidecar asli (tersembunyi di belakang stream) selalu diparkir otomatis di sudut luar layar
  iPad, jauh dari Mac, supaya pointer tidak tersesat ke sana. Kalau ada yang memindahkannya
  (misalnya System Settings saat Arrange ditutup), PortraitPad mengembalikannya.

## Gestur sentuh di iPad

| Gerakan | Hasil |
|---|---|
| Ketuk 1 jari | Klik kiri di titik itu |
| 1 jari geser (langsung atau setelah ditahan) | Scroll mengikuti jari, dengan momentum |
| 2 jari geser ke kiri / kanan, lalu angkat | Pindah Space / aplikasi full-screen di layar iPad (Ctrl+→ / Ctrl+←) |
| Gerakan 2 jari lainnya, 3 jari atau lebih | Diabaikan |

Gerakan trackpad dan mouse tidak pernah diubah. Scroll tidak memindah pointer: macOS mengirim
scroll ke jendela di bawah pointer (dan aplikasi Electron seperti Claude mengabaikan scroll yang
dikirim langsung), jadi kalau pointer tidak sedang di atas jendela yang disentuh, pointer
"dipinjam" dalam keadaan tersembunyi lalu dikembalikan setelah scroll dan momentum selesai.
Menggerakkan trackpad selama itu langsung mengembalikan pointer dan menghentikan scroll.
Swipe 2 jari meminjam pointer dengan cara yang sama (150 ms), karena macOS memindah Space di layar
tempat pointer berada.

Sidecar mengirim sentuhan jari ke *gesture recognizer* AppKit (event `directTouch`), bukan sebagai
event mouse. Lihat komentar di `InputView` (`Sources/main.swift`) untuk detailnya.

## Build dan pasang

Panduan langkah demi langkah dari nol (tanpa jalan otomatis saat login): [SETUP.md](SETUP.md).

Butuh Command Line Tools (Swift 6.x), tanpa Xcode.

```bash
./build.sh                                   # → build/PortraitPad.app
osascript -e 'quit app "PortraitPad"'
rm -rf ~/Applications/PortraitPad.app && cp -R build/PortraitPad.app ~/Applications/
open ~/Applications/PortraitPad.app
```

Supaya jalan otomatis saat login: System Settings ▸ General ▸ Login Items ▸ tambahkan
`~/Applications/PortraitPad.app`.

### Izin

Sekali saja, di System Settings ▸ Privacy & Security:

- **Screen & System Audio Recording**: untuk merekam layar virtual.
- **Accessibility**: untuk meneruskan klik, scroll, dan Ctrl+arrow.

### Sertifikat tanda tangan lokal

`build.sh` menandatangani dengan identitas `PortraitPad Local Signing` dari keychain login. Dengan
tanda tangan yang tetap, izin di atas tidak ter-reset setiap kompilasi ulang (tanda tangan ad-hoc
berubah tiap build). Kalau identitasnya tidak ada, `build.sh` jatuh ke ad-hoc dan memberi peringatan.

Membuat identitasnya (sekali per Mac):

```bash
cat > /tmp/pp.cfg <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = PortraitPad Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
cd /tmp
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout pp.key -out pp.pem -days 3650 -config pp.cfg
/usr/bin/openssl pkcs12 -export -inkey pp.key -in pp.pem -out pp.p12 -passout pass:pp -name "PortraitPad Local Signing"
security import pp.p12 -k ~/Library/Keychains/login.keychain-db -P pp -T /usr/bin/codesign
rm pp.key pp.p12 pp.cfg
```

Saat `codesign` pertama kali memakai kunci ini, macOS meminta password login. Pilih **Always Allow**.

## Debug

```bash
defaults write local.z.PortraitPad debugInput -bool true    # catat tiap sentuhan
tail -f ~/Library/Logs/PortraitPad.log
```

Matikan lagi dengan `defaults delete local.z.PortraitPad debugInput`, lalu
jalankan ulang aplikasinya.

`Tools/eventprobe.swift` adalah alat terpisah yang dipakai untuk mencari tahu apa yang sebenarnya
dikirim Sidecar untuk tiap gerakan jari. Instruksinya tampil tegak di iPad, dan semua event dicatat:

```bash
swiftc -O Tools/eventprobe.swift -o build/eventprobe
build/eventprobe --cursortest > probe.log    # juga: --passive, --level=N
```

## Batasan

- Sidecar dikunci Apple di **60 Hz**. Layar ProMotion 120 Hz tidak bisa dipakai lewat jalur ini.
- `CGVirtualDisplay` dan properti `SetsCursorInBackground` (menyembunyikan pointer dari latar belakang)
  adalah API privat. Update macOS bisa mengubahnya (diverifikasi masih jalan di macOS 27).
- Desktop Sidecar asli tetap ada di belakang stream. Jendela yang terseret ke sana tidak terlihat.
