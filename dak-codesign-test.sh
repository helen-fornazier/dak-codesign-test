#!/bin/bash

set -eo pipefail

signfile=/home/koike/caneca/opw/linux/scripts/sign-file
filein=${1-$PWD/test-objects.tar.xz}
conf_file="/etc/dsigning-box/secure-boot-code-sign.conf"
# yubikey default key
key=010203040506070801020304050607080102030405060708
opensc_mod=/usr/lib/x86_64-linux-gnu/opensc-pkcs11.so

gen_key_no_pass() {
	openssl genrsa -out test-key.rsa 2048
	openssl req -new -x509 -sha256 \
	        -subj '/CN=test-key' -key test-key.rsa -out test-cert.pem
}

gen_key_with_pass() {
	openssl genrsa -des3 -passout pass:121212 -out test-key.rsa 2048
	openssl req -passin pass:121212 -new -x509 -sha256 \
		-subj '/CN=test-key' -key test-key.rsa -out test-cert.pem
}

if [ ! -f ~/.config/pkcs11/modules/yubikey ]; then
	echo "module: ${opensc_mod}" > ~/.config/pkcs11/modules/yubikey
fi

# get token URI
token_uri=$(p11tool --list-tokens | grep "token=PIV_II")
token_uri=${token_uri#*URL: }

# ----------------------------------
# No yubikey no password
# ----------------------------------

mkdir no-yub-no-pass && cd no-yub-no-pass

# Gen Key
gen_key_no_pass

#Add key in certdir
mkdir certdir
certdir="$PWD/certdir"
certutil -N --empty-password -d "$certdir"
openssl pkcs12 -export \
        -inkey test-key.rsa -in test-cert.pem \
        -out efi-image.p12 -passout pass: \
        -name efi-image
pk12util -i efi-image.p12 -d "$certdir" -K '' -W ''

# Set dsigning-box dir
echo $PWD
mkdir -p dsigning_box_dir/img
cp $filein dsigning_box_dir/img
dsigning_box_dir="$PWD/dsigning_box_dir"

sudo tee 1>/dev/null "$conf_file" << EOF
IMG_DIR="${dsigning_box_dir}/img"
SIG_DIR="${dsigning_box_dir}/sig"

EFI_CERT_DIR="${certdir}" 
EFI_CERT_NAME="efi-image"
EFI_TOKEN_NAME="NSS Certificate DB"

LINUX_SIGNFILE=$signfile
LINUX_MODULES_PRIVKEY=test-key.rsa
LINUX_MODULES_CERT=test-cert.pem
EOF

fileout=$(secure-boot-code-sign ${filein##*/})
tar xvaf $fileout
cd ../

# ----------------------------------
# No yubikey with password
# ----------------------------------

mkdir no-yub-with-pass && cd no-yub-with-pass

# Gen key
gen_key_with_pass

#Add key in certdir
mkdir certdir
certdir="$PWD/certdir"
echo 565656 > /tmp/password
certutil -N -d "$certdir" -f /tmp/password
openssl pkcs12 -export -passin pass:121212 \
        -inkey test-key.rsa -in test-cert.pem \
        -out efi-image.p12 -passout pass:343434 \
        -name efi-image
pk12util -i efi-image.p12 -d "$certdir" -K '565656' -W '343434'

# Set dsigning-box dir
mkdir -p dsigning_box_dir/img
cp $filein dsigning_box_dir/img
dsigning_box_dir="$PWD/dsigning_box_dir"

sudo tee 1>/dev/null "$conf_file" << EOF
IMG_DIR="${dsigning_box_dir}/img"
SIG_DIR="${dsigning_box_dir}/sig"

EFI_CERT_DIR="${certdir}" 
EFI_CERT_NAME="efi-image"
EFI_TOKEN_NAME="NSS Certificate DB"
EFI_SIGN_PIN=565656

LINUX_SIGNFILE=$signfile
LINUX_MODULES_PRIVKEY=test-key.rsa
LINUX_MODULES_CERT=test-cert.pem
LINUX_SIGN_PIN=121212
EOF

fileout=$(secure-boot-code-sign ${filein##*/})
tar xvaf $fileout
cd ../

# ----------------------------------
# With yubikey no password
# ----------------------------------

mkdir with-yub-no-pass && cd with-yub-no-pass

# Gen Key
#gen_key_no_pass
#
## Insert key in yubikey
yubico-piv-tool -k $key -a generate -s 9c > yubico.pub
yubico-piv-tool -s 9c -S '/CN=test-key' -P 123456  -a verify -a selfsign < yubico.pub > test-cert.pem
#yubico-piv-tool -k $key -a import-key -s 9c < test-key.rsa
yubico-piv-tool -k $key -a import-certificate -s 9c < test-cert.pem

# Add cert in cert database
mkdir certdir
certdir="$PWD/certdir"
certutil --empty-password -A -n "efi-cert" -t ,,T -d $certdir -a -i test-cert.pem

# Set dsigning-box dir
mkdir -p dsigning_box_dir/img
cp $filein dsigning_box_dir/img
dsigning_box_dir="$PWD/dsigning_box_dir"

sudo tee 1>/dev/null "$conf_file" << EOF
IMG_DIR="${dsigning_box_dir}/img"
SIG_DIR="${dsigning_box_dir}/sig"

EFI_CERT_DIR="${certdir}" 
EFI_CERT_NAME="Certificate for Digital Signature"
EFI_TOKEN_NAME="PIV_II (PIV Card Holder pin)"
EFI_SIGN_PIN=123456 # yubikey default pin

LINUX_SIGNFILE=${signfile}
LINUX_MODULES_PRIVKEY="${token_uri}"
LINUX_MODULES_CERT=test-cert.pem
LINUX_SIGN_PIN=123456 # yubikey default pin
EOF

# workaround needed for pesign to find the token
ln -s ${opensc_mod} $certdir/libnssckbi.so
fileout=$(secure-boot-code-sign ${filein##*/})
tar xvaf $fileout
cd ../

# ----------------------------------
# With yubikey with password
# ----------------------------------

mkdir with-yub-with-pass && cd with-yub-with-pass

# Gen Key
gen_key_with_pass

# Insert key in yubikey
# the password of test-key will be asked here only to load it in the yubikey
# it is not used again to sign the file
echo ""
echo "Use pass 121212 to load the priv key in the yubikey"
yubico-piv-tool -k $key -a import-key -s 9c < test-key.rsa
yubico-piv-tool -k $key -a import-certificate -s 9c < test-cert.pem

# Add cert in cert database
mkdir certdir
certdir="$PWD/certdir"
echo 989898 > /tmp/password
certutil -f /tmp/password -A -n "efi-cert" -t ,,T -d $certdir -a -i test-cert.pem

# Set dsigning-box dir
mkdir -p dsigning_box_dir/img
cp $filein dsigning_box_dir/img
dsigning_box_dir="$PWD/dsigning_box_dir"

sudo tee 1>/dev/null "$conf_file" << EOF
IMG_DIR="${dsigning_box_dir}/img"
SIG_DIR="${dsigning_box_dir}/sig"

EFI_CERT_DIR="${certdir}" 
EFI_CERT_NAME="Certificate for Digital Signature"
EFI_TOKEN_NAME="PIV_II (PIV Card Holder pin)"
EFI_SIGN_PIN=123456 # yubikey default pin

LINUX_SIGNFILE=$signfile
LINUX_MODULES_PRIVKEY="${token_uri}"
LINUX_MODULES_CERT=test-cert.pem
LINUX_SIGN_PIN=123456 # yubikey default pin
EOF

# workaround needed for pesign to find the token
ln -s ${opensc_mod} $certdir/libnssckbi.so
fileout=$(secure-boot-code-sign ${filein##*/})
tar xvaf $fileout
cd ../

exit 0
