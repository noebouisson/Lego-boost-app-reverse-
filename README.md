# Blockwork

App iPad de programmation visuelle par blocs pour un hub robotique Bluetooth
compatible « LEGO Wireless Protocol 3.0 » (documentation publique :
https://lego.github.io/lego-ble-wireless-protocol-docs/).

Projet indépendant, sans lien avec le groupe LEGO. Aucun code ni asset tiers.

## État d'avancement

| Étape | Contenu | État |
|---|---|---|
| 1 | Couche BLE `HubLink` (codec, Bluetooth, faux hub, session) | fait |
| 2 | Moteur d'exécution `BlockEngine` + tests | à venir |
| 3 | Éditeur SwiftUI et projet Xcode | à venir |

## Tester la couche BLE

```sh
cd Packages/BoostCore
swift test
```

Ou dans Xcode : ouvrir `Packages/BoostCore/Package.swift`, puis ⌘U.

## Points du protocole non couverts par la doc officielle

Repérés dans le code par la mention « NON DOCUMENTÉ » (`LWPConstants.swift`) :

- numéros de mode du capteur couleur/distance (mode 8) et du capteur d'inclinaison (mode 0) ;
- unité de la distance (échelle brute 0 à 10) ;
- correspondance numéro → teinte pour la LED et le capteur de couleur ;
- détection de secousse, déduite d'une variation rapide de l'inclinaison.

À la connexion, la session interroge le nom de chaque mode utilisé et écrit un
avertissement dans le journal s'il ne correspond pas à celui attendu.
