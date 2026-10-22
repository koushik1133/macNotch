#!/bin/zsh
# create-signing-identity.sh: gives SparkV builds a code signature that stays
# the same across rebuilds, so macOS privacy grants stop disappearing.
#
# WHY THIS EXISTS
# macOS records each privacy grant (Accessibility, Screen Recording, Camera,
# Automation...) in its TCC database together with the app's "designated
# requirement", a rule describing which code the grant belongs to. Without a
# certificate, build.sh signs ad hoc, and the requirement of an ad-hoc app is
# its exact code hash ("cdhash H\"a215...\""). Every rebuild has a new hash. The
# old grant stays in System Settings with its switch on, but it no longer
# matches the new binary, so SparkV keeps reporting Accessibility as missing.
#
# A certificate fixes that: the requirement becomes "identifier com.sparkv.app
# and certificate leaf = H\"<hash of this certificate>\"", which every future
# build signed with it meets.
# build.sh already signs with an identity named "NotchIsland Developer" when
# one exists. This script creates it.
#
# WHAT IT DOES (once; running it again only reports what is there)
#   1. Generates a 2048-bit RSA key and a self-signed certificate with the
#      Code Signing extended key usage, valid for 10 years (openssl).
#   2. Imports both into your login keychain and lets /usr/bin/codesign use the
#      private key (security import -T).
#   3. Optionally lets codesign use the key without the "codesign wants to
#      access key" dialog (security set-key-partition-list, needs your login
#      password; skip it and click "Always Allow" on the first build instead).
#   4. Marks the certificate as trusted for code signing for your user
#      (security add-trusted-cert; macOS asks for your password in a dialog).
#      Signing works without this step; it only makes the identity "valid".
# Nothing is sent anywhere, no system-wide setting changes, and the key never
# leaves your login keychain. Temporary files are deleted on exit.
#
# USAGE
#   ./Scripts/create-signing-identity.sh
#
# TO UNDO
#   Keychain Access > login > My Certificates > delete "NotchIsland Developer".
#   build.sh then signs ad hoc again.
#
# Overrides, mainly for testing against a throwaway keychain:
#   SPARKV_KEYCHAIN           keychain file to use (default: login keychain)
#   SPARKV_KEYCHAIN_PASSWORD  password for step 3 (skips the question)
#   SPARKV_SKIP_TRUST=1       skip step 4
#   SPARKV_IDENTITY_NAME      certificate name (default: NotchIsland Developer)

set -euo pipefail

NAME="${SPARKV_IDENTITY_NAME:-NotchIsland Developer}"
KEYCHAIN="${SPARKV_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
PROJECT_DIR="${0:A:h:h}"

say()  { print -r -- "$@"; }
step() { print -r -- ""; print -r -- "==> $@"; }
fail() { print -r -- "error: $@" >&2; exit 1; }

next_steps() {
  cat <<EOF

Next steps
  1. Rebuild:        cd "$PROJECT_DIR" && ./build.sh
     The log should end with "Signed with: $NAME". If macOS asks whether
     codesign may use the key, choose "Always Allow".
  2. Relaunch SparkV from build/SparkV.app.
  3. One last time, renew the grants that belonged to the old ad-hoc builds:
     System Settings > Privacy & Security > Accessibility: select SparkV,
     click the minus (-) button, then + and add build/SparkV.app (or drag it
     in) and turn it on. Do the same under Screen Recording. SparkV's
     Permissions window (gear menu > Permissions & Setup) has buttons for it.
  From now on, rebuilding keeps every grant.
EOF
}

[[ -f "$KEYCHAIN" ]] || fail "keychain not found: $KEYCHAIN"

# --- Already set up? ---------------------------------------------------------
# find-identity lists only certificates whose private key is present, which is
# exactly what codesign needs. Without -v it includes untrusted ones too.
# The output has a "Matching" and a "Valid" section; count matching ones only.
matching=$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
  | sed -n '/Matching identities/,/Valid identities/p' | grep -c "\"$NAME\"" || true)
matching=${matching:-0}

if (( matching > 1 )); then
  fail "$matching identities named \"$NAME\" exist, so codesign would report an
ambiguous identity. Keep one: Keychain Access > login > My Certificates, delete
the extras, then run this script again."
fi

if (( matching == 1 )); then
  say "The code-signing identity \"$NAME\" already exists in $(basename "$KEYCHAIN")."
  if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    say "It is trusted for code signing."
  else
    say "It is not marked as trusted; that is fine for signing SparkV."
  fi
  next_steps
  exit 0
fi

# A certificate with that name but no private key cannot sign, and a second
# one would make the name ambiguous later. Don't delete anything: ask.
if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  fail "a certificate named \"$NAME\" exists without its private key, so it
cannot sign. Delete it in Keychain Access (login > Certificates), then run this
script again."
fi

# --- 1. Key and certificate --------------------------------------------------
# macOS ships LibreSSL as /usr/bin/openssl. Prefer it: its PKCS#12 files use
# the SHA1/3DES encryption that `security import` reads. OpenSSL 3 needs
# -legacy for the same format.
OPENSSL=/usr/bin/openssl
[[ -x "$OPENSSL" ]] || OPENSSL=$(command -v openssl) || fail "openssl not found"
P12_FLAGS=()
if ! "$OPENSSL" version | grep -q LibreSSL; then
  P12_FLAGS=(-legacy)
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

step "Creating a self-signed code-signing certificate \"$NAME\""
cat > "$WORK/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = codesign
[ dn ]
CN = $NAME
[ codesign ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null \
  || fail "openssl could not create the certificate"

# Random one-time password for the PKCS#12 bundle; it only protects the file
# in the temp folder for the few seconds before it is imported.
P12_PASS=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export "${P12_FLAGS[@]}" -name "$NAME" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/identity.p12" -passout "pass:$P12_PASS" 2>/dev/null \
  || fail "openssl could not package the certificate"

# --- 2. Import ---------------------------------------------------------------
step "Importing it into $(basename "$KEYCHAIN")"
# Only codesign goes on the key's access list. /usr/bin/security is left off
# on purpose: anything allowed there could use the key silently, and whoever
# can sign with it can pass as SparkV and inherit its privacy grants.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASS" \
  -T /usr/bin/codesign >/dev/null \
  || fail "security import failed (is the keychain locked?)"

security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\"" \
  || fail "the certificate was imported but codesign can't see it as an identity"
say "Imported."

# --- 3. Let codesign use the key without a dialog (optional) -----------------
step "Letting codesign use the key without asking (optional)"
KC_PASS="${SPARKV_KEYCHAIN_PASSWORD:-}"
if [[ -z "$KC_PASS" && -t 0 ]]; then
  say "Enter your login keychain password (usually your Mac password) so codesign"
  say "never shows a key-access dialog, or press Return to skip and click"
  print -rn -- "\"Always Allow\" on the first build instead: "
  read -rs KC_PASS || KC_PASS=""
  print
fi
if [[ -n "$KC_PASS" ]]; then
  # `security import` labels every key "Imported Private Key", so first give
  # this key the certificate's name (matched by its public-key hash), then
  # change the access list of that one key only, never other keys.
  cat > "$WORK/label.swift" <<'SWIFT'
import Foundation
import Security
// label.swift <cert.pem> <keychain> <label>: renames the private key that
// belongs to the certificate.
let args = CommandLine.arguments
let pem = (try? String(contentsOfFile: args[1], encoding: .utf8)) ?? ""
let base64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
guard let der = Data(base64Encoded: base64),
      let certificate = SecCertificateCreateWithData(nil, der as CFData),
      let publicKey = SecCertificateCopyKey(certificate),
      let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
      let applicationLabel = attributes[kSecAttrApplicationLabel] as? Data else { exit(2) }
var keychain: SecKeychain?
guard SecKeychainOpen(args[2], &keychain) == errSecSuccess, let keychain else { exit(3) }
let query: [CFString: Any] = [
    kSecClass: kSecClassKey,
    kSecAttrKeyClass: kSecAttrKeyClassPrivate,
    kSecAttrApplicationLabel: applicationLabel,
    kSecMatchSearchList: [keychain],
]
exit(SecItemUpdate(query as CFDictionary, [kSecAttrLabel: args[3]] as CFDictionary) == errSecSuccess ? 0 : 1)
SWIFT
  if ! xcrun swift "$WORK/label.swift" "$WORK/cert.pem" "$KEYCHAIN" "$NAME" >/dev/null 2>&1; then
    say "Couldn't name the key, so its access list was left alone. The first"
    say "build asks once instead; choose \"Always Allow\"."
  elif security set-key-partition-list -S apple-tool:,apple:,codesign: -s -t private \
       -l "$NAME" -k "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1; then
    say "Done."
  else
    say "Couldn't update the key's access list (wrong password?). Skipped; the"
    say "first build asks once instead."
  fi
else
  say "Skipped. The first build asks once; choose \"Always Allow\"."
fi
unset KC_PASS

# --- 4. Trust for code signing ------------------------------------------------
if [[ "${SPARKV_SKIP_TRUST:-0}" != "1" ]]; then
  step "Trusting the certificate for code signing (macOS asks for your password)"
  if security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" 2>/dev/null; then
    say "Trusted."
  else
    say "Not changed (cancelled or not allowed). Signing works anyway."
  fi
fi

step "Ready"
security find-identity -p codesigning "$KEYCHAIN" | sed -n "/\"$NAME\"/p" | head -1
next_steps
