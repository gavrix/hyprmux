#!/usr/bin/env bash
# Create a self-signed code-signing identity, "Hyprmux Local Signing", in the login
# keychain. scripts/bundle.sh signs with it when it exists.
#
# Why: an ad-hoc signature changes with every build, and macOS ties privacy permissions
# (Screen Recording, Accessibility, folder access) to the signature, so each rebuild
# silently loses them. A stable certificate keeps the app's designated requirement the
# same across builds, so a permission granted once stays granted.
#
# The certificate is local only: not trusted by anyone, valid for 10 years, never leaves
# this Mac. Remove it with:
#   security delete-identity -c "Hyprmux Local Signing"
set -euo pipefail
NAME="Hyprmux Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<EOF
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

# macOS's LibreSSL writes a PKCS#12 that `security import` reads (OpenSSL 3's default
# encryption it doesn't).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout pass:hyprmux
# -T lets codesign use the key without asking each time.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P hyprmux -T /usr/bin/codesign >/dev/null
echo "created \"$NAME\" in the login keychain"
