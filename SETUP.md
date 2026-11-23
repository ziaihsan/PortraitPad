# Setting up PortraitPad

These steps install PortraitPad in `~/Applications` so you can open it from Spotlight. It will not
start when you log in; it runs only when you open it.

Last checked on 24 November 2026 with macOS 27.2.1 and Swift 6.4.2 (Command Line Tools).

## 1. Build

```bash
cd /tmp
git clone https://github.com/ziaihsan/PortraitPad.git
cd PortraitPad
./build.sh
```

The app is built at `build/PortraitPad.app`. You can ignore the warning
`'numberOfTouchesRequired' was deprecated`.

If you see `'PortraitPad Local Signing' not in keychain, signing ad-hoc`, the app still works, but
macOS will ask for its permissions again after every rebuild. Step 5 fixes this.

## 2. Install

```bash
osascript -e 'quit app "PortraitPad"' 2>/dev/null
mkdir -p ~/Applications
rm -rf ~/Applications/PortraitPad.app
cp -R build/PortraitPad.app ~/Applications/
```

Delete the cloned folder afterwards. Otherwise Spotlight shows two apps named PortraitPad:

```bash
cd ~ && rm -rf /tmp/PortraitPad
```

## 3. Use it

1. Connect your iPad with Sidecar: Control Center ▸ Screen Mirroring ▸ your iPad, as an extended
   display.
2. Open PortraitPad from Spotlight. An iPad icon appears in the menu bar.
3. The portrait display appears on the iPad. Hold the iPad upright.
4. To stop, click the iPad icon in the menu bar and choose Quit PortraitPad.

## 4. Permissions

macOS asks for these the first time, and again after a rebuild without the certificate from step 5.
Both are in System Settings ▸ Privacy & Security:

- Screen & System Audio Recording is required. Without it the iPad stays black.
- Accessibility is needed for touch. Without it you still see the picture, but taps and scrolls do
  nothing.

After you allow them, quit PortraitPad and open it again.

## 5. Optional: a local signing certificate

`build.sh` signs the app with the identity `PortraitPad Local Signing` if it is in your login
keychain. macOS ties permissions to the signature, and an ad-hoc signature changes with every
build, so a fixed identity keeps your permissions across rebuilds. Create it once per Mac:

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

The first time `codesign` uses this key, macOS asks for your login password. Choose Always Allow.

## If something does not work

```bash
tail -20 ~/Library/Logs/PortraitPad.log
```

- `Accessibility not granted yet` means the Accessibility permission is missing.
- No `Sidecar found` line means Sidecar is not connected.
- `capture failed` means the Screen Recording permission is missing.
