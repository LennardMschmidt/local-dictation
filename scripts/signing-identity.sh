#!/bin/bash
# Creates or unlocks a self-signed code signing identity "LocalDictation Local Signing" in its own
# keychain and prints the keychain path.
#
# macOS ties privacy permissions (Microphone, Accessibility, Input Monitoring) to the code
# signature. An ad-hoc signature changes with every build, so every rebuild would lose the
# permissions. A fixed certificate keeps them.
#
# The keychain password is random and stored only in the login keychain under the service name
# below. It is never printed or written to a file.
set -euo pipefail

NAME="LocalDictation Local Signing"
SERVICE="localdictation-signing-keychain"
KEYCHAIN="$HOME/Library/Keychains/localdictation-signing.keychain-db"

password() {
  security find-generic-password -s "$SERVICE" -a "$USER" -w 2>/dev/null
}

has_identity() {
  [ -f "$KEYCHAIN" ] && security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1
}

if ! has_identity; then
  [ -f "$KEYCHAIN" ] && security delete-keychain "$KEYCHAIN"
  if ! password >/dev/null; then
    security add-generic-password -s "$SERVICE" -a "$USER" -w "$(openssl rand -base64 24)" -U
  fi
  PW="$(password)"
  security create-keychain -p "$PW" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  P12PW="$(openssl rand -hex 16)"
  # macOS can only import PKCS#12 files with the older SHA1/3DES algorithms (-legacy in OpenSSL 3).
  LEGACY=""
  openssl version | grep -q '^OpenSSL 3' && LEGACY="-legacy"
  openssl pkcs12 -export $LEGACY -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$P12PW" 2>/dev/null
  security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12PW" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null
fi

security unlock-keychain -p "$(password)" "$KEYCHAIN"
echo "$KEYCHAIN"
