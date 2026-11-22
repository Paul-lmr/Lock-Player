# LockPlayer — mini guide du logo

**Idée :** trois barres d'égaliseur en argent sur un bleu nuit presque noir. Ce sont les barres qui bougent avec le son dans le lecteur.

## Fichiers (`final/`)

| Fichier | Usage |
|---|---|
| `lockplayer-icon.svg` | Icône d'app (tuile bleu nuit, barres argent dégradées). Master pour 128 px et plus. |
| `lockplayer-icon-small.svg` | Icône simplifiée pour 16 à 64 px : barres plus épaisses, sans reflet. |
| `lockplayer-mark.svg` | Symbole seul (barres), bleu nuit, sur fond clair. |
| `lockplayer-mark-white.svg` / `-mono-c9d0de.svg` | Symbole sur fond sombre (blanc ou argent). |
| `lockplayer-mark-black.svg` | Une couleur, impression noir et blanc. |
| `lockplayer-mark-small.svg` | Symbole simplifié, utilisé pour l'icône de barre des menus (modèle macOS). |
| `lockplayer-horizontal-light.svg` / `-dark.svg` | Logo + nom, pour fond clair / fond sombre (PNG dans `png/`). |
| `web/` | favicon.ico, favicon.svg, icônes PNG, webmanifest, extrait `<head>`. |

Dans l'app : `LockPlayer/Assets.xcassets/AppIcon` et `MenuBarIcon`.

## Couleurs

| Nom | HEX | RGB | Rôle |
|---|---|---|---|
| Bleu nuit | `#111A33` | 17, 26, 51 | Couleur principale, fond, symbole sur fond clair |
| Bleu nuit clair → foncé | `#1B2A4E` → `#080D1C` | | Dégradé de la tuile d'icône |
| Argent | `#C9D0DE` | 201, 208, 222 | Symbole sur fond sombre |
| Argent clair → foncé | `#EEF1F7` → `#98A3BA` | | Dégradé des barres de l'icône |

## Règles

- **Espace libre :** autour du logo, au moins la largeur d'une barre.
- **Tailles minimales :** symbole 16 px (version simplifiée en dessous de 64 px) ; logo horizontal 24 px de haut.
- **Fonds :** bleu nuit, noir ou très sombre → version argent/blanche ; blanc ou clair → version bleu nuit.
- **À éviter :** changer la hauteur relative des barres, ajouter une 4ᵉ barre, des couleurs vives ou de l'ombre portée, déformer le logo, poser la version bleu nuit sur un fond sombre.

## Typographie

Le nom « LockPlayer » est dessiné à partir de **SF Pro** (police système d'Apple, graisse ~620), converti en tracés vectoriels. La licence de SF Pro réserve son usage aux interfaces des plateformes Apple : très bien pour l'app, mais pour un usage commercial hors Apple (site, goodies), redessine le nom avec une police sous licence libre (Inter, par exemple).

## Présentation

`presentation.html` (et les images dans `slides/`) : la planche avec l'icône en situation.
