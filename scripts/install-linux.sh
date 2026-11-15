#!/usr/bin/env bash
# Prépare un PC Linux pour installer Blockwork sur un iPad branché en USB :
# pilotes USB, outil de signature Impactor (Flatpak), et dernière compilation de l'app.
set -euo pipefail

IPA_URL="https://github.com/noebouisson/Lego-boost-app-reverse-/releases/download/latest-build/Blockwork-unsigned.ipa"
DEST="$HOME/Blockwork"
IMPACTOR="dev.khcrysalis.PlumeImpactor"

echo "==> 1/4 Paquets système (mot de passe administrateur demandé)"
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y usbmuxd libimobiledevice-utils flatpak curl
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y usbmuxd libimobiledevice-utils flatpak curl
elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm usbmuxd libimobiledevice flatpak curl
elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y usbmuxd imobiledevice-tools flatpak curl
else
    echo "Distribution non reconnue : installe usbmuxd, libimobiledevice et flatpak à la main, puis relance." >&2
    exit 1
fi

echo "==> 2/4 Outil de signature Impactor"
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub "$IMPACTOR"

echo "==> 3/4 Téléchargement de l'app"
mkdir -p "$DEST"
curl -fL --retry 3 -o "$DEST/Blockwork-unsigned.ipa" "$IPA_URL"
ls -lh "$DEST/Blockwork-unsigned.ipa"

echo "==> 4/4 Recherche de l'iPad"
if idevice_id -l | grep -q .; then
    echo "iPad détecté : $(idevice_id -l | head -n 1)"
else
    echo "Aucun iPad détecté. Branche-le, déverrouille-le, accepte « Faire confiance », puis lance : idevice_id -l"
fi

cat <<FIN

Tout est prêt. Ensuite :
  1. Laisse l'iPad branché et déverrouillé.
  2. Lance :  flatpak run $IMPACTOR
  3. Dans Impactor, ouvre le fichier  $DEST/Blockwork-unsigned.ipa
     connecte-toi avec ton identifiant Apple, puis installe.
  4. Sur l'iPad : Réglages > Général > VPN et gestion de l'appareil > faire confiance,
     et Réglages > Confidentialité et sécurité > Mode développeur > activer.
FIN
