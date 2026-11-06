#!/bin/zsh
# Recreate "WhisperFlow Dev" with a proper Code Signing extension.
# The plain openssl cert from before has no EKU, so macOS's
# find-identity -p codesigning never lists it.
set -x
security delete-certificate -c "WhisperFlow Dev" ~/Library/Keychains/login.keychain-db 2>/dev/null || true
cat > /tmp/wf-cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = WhisperFlow Dev
C = US
ST = Local
L = Local
O = WhisperFlow
[ext]
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
openssl req -new -x509 -keyout /tmp/wf-key.pem -out /tmp/wf-cert.pem -days 3650 -nodes -config /tmp/wf-cert.cnf
openssl pkcs12 -export -inkey /tmp/wf-key.pem -in /tmp/wf-cert.pem -out /tmp/wf-dev.p12 -passout pass:temp
security import /tmp/wf-dev.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -d -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/wf-cert.pem || echo "trust add needs admin approval, continuing"
echo "=== CHECK ==="
security find-identity -v -p codesigning | grep -i whisper || echo "STILL NOT FOUND"
