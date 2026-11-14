# Blockwork

App iPad de programmation visuelle par blocs pour un hub robotique Bluetooth
compatible « LEGO Wireless Protocol 3.0 » (documentation publique :
https://lego.github.io/lego-ble-wireless-protocol-docs/).

Projet indépendant, sans lien avec le groupe LEGO. Aucun code ni asset tiers.

## Installer sur un iPad

Il faut un Mac avec Xcode 16 ou plus récent.

1. Ouvre `Blockwork.xcodeproj`.
2. Sélectionne la cible **Blockwork**, onglet **Signing & Capabilities**, et choisis ton équipe
   (un identifiant Apple gratuit suffit). Remplace l'identifiant `com.example.blockwork` par le tien.
3. Branche l'iPad en USB, déverrouille-le, accepte « Faire confiance à cet ordinateur ».
   Sur l'iPad : Réglages → Confidentialité et sécurité → **Mode développeur** → activer, puis redémarrer.
4. Choisis l'iPad comme destination dans Xcode, puis ⌘R.
5. Au premier lancement, sur l'iPad : Réglages → Général → VPN et gestion de l'appareil → faire confiance
   à ton certificat de développeur.

Sans iPad, choisis un simulateur iPad : l'app démarre en mode simulation (faux hub).

## Lancer les tests

```sh
cd Packages/BoostCore
swift test
```

Ou dans Xcode : ouvrir `Packages/BoostCore/Package.swift`, puis ⌘U.

## Organisation

| Dossier | Contenu |
|---|---|
| `Packages/BoostCore/Sources/HubLink` | Couche BLE : codec du protocole, Bluetooth, faux hub, session |
| `Packages/BoostCore/Sources/BlockEngine` | Modèle des blocs, catalogue, interpréteur, opérations d'édition |
| `Packages/BoostCore/Sources/AppCore` | Pont moteur ↔ BLE, sauvegarde des projets, calcul des cibles de dépôt |
| `App` | App SwiftUI : accueil, éditeur, palette, connexion, sons |

## Points du protocole non couverts par la doc officielle

Repérés dans le code par la mention « NON DOCUMENTÉ » (`LWPConstants.swift`) :

- numéros de mode du capteur couleur/distance (mode 8) et du capteur d'inclinaison (mode 0) ;
- unité de la distance (échelle brute 0 à 10) ;
- correspondance numéro → teinte pour la LED et le capteur de couleur ;
- détection de secousse, déduite d'une variation rapide de l'inclinaison.

À la connexion, la session interroge le nom de chaque mode utilisé et écrit un
avertissement dans le journal s'il ne correspond pas à celui attendu.
