# Cara memasang PortraitPad (dari nol)

Langkah ini memasang PortraitPad ke `~/Applications` supaya bisa dibuka lewat Spotlight.
Aplikasi **tidak** dijalankan otomatis saat login. Ia hanya jalan saat kamu membukanya sendiri.

Terakhir dicoba: 24 Nov 2026, macOS 27.2.1, Swift 6.4.2 (Command Line Tools).

## 1. Clone dan build

```bash
cd /tmp
gh repo clone ziaihsan/PortraitPad
cd PortraitPad
./build.sh
```

Hasilnya `build/PortraitPad.app`. Peringatan `numberOfTouchesRequired was deprecated` boleh diabaikan.

Kalau muncul `'PortraitPad Local Signing' not in keychain, signing ad-hoc`, aplikasinya tetap jalan,
tapi izin harus diberikan ulang setiap kali build ulang. Untuk mencegahnya, buat sertifikatnya
sekali (lihat README, bagian "Sertifikat tanda tangan lokal").

## 2. Pasang ke Applications

```bash
osascript -e 'quit app "PortraitPad"' 2>/dev/null
mkdir -p ~/Applications
rm -rf ~/Applications/PortraitPad.app
cp -R build/PortraitPad.app ~/Applications/
```

Setelah itu hapus folder hasil clone supaya Spotlight tidak menampilkan dua "PortraitPad":

```bash
cd ~ && rm -rf /tmp/PortraitPad
```

Jangan tambahkan ke Login Items kalau tidak ingin aplikasinya jalan otomatis.

## 3. Pemakaian

1. Sambungkan iPad lewat **Sidecar** (Control Center ▸ Screen Mirroring ▸ pilih iPad, mode Extended).
2. Buka **PortraitPad** lewat Spotlight. Ikon iPad muncul di menu bar.
3. Layar portrait langsung muncul di iPad. Pegang iPad dalam posisi tegak.
4. Selesai: klik ikon iPad di menu bar ▸ **Quit PortraitPad**.

## 4. Izin (pertama kali, dan setelah build ulang tanpa sertifikat lokal)

System Settings ▸ Privacy & Security:

- **Screen & System Audio Recording**: wajib, untuk menampilkan gambar.
- **Accessibility**: untuk ketuk, scroll, dan swipe dari iPad. Tanpa izin ini gambar tetap tampil,
  tapi sentuhan tidak berfungsi.

Setelah memberi izin, tutup lalu buka lagi PortraitPad.

## Cek kalau ada masalah

```bash
tail -20 ~/Library/Logs/PortraitPad.log
```

- `Accessibility not granted yet`: izin Accessibility belum diberikan.
- Tidak ada baris `Sidecar found`: Sidecar belum tersambung.
- `capture failed`: izin Screen Recording belum diberikan.
