# My2DCAD — instructions pour Claude

Application de dessin 2D (CAO) pour Mac reprenant les principales fonctions de Microsoft Visio.
Le code doit être fiable, performant et sécurisé. Agis en expert de Visio : quand une fonction
existe dans Visio, reproduis son comportement et son vocabulaire.

## Travailler avec Emmanuel

- Réponses, commentaires de code, libellés de l'interface et messages de commit : **en français**.
- Pose des questions (choix multiples) quand une demande est ambiguë, avant de coder.
- Après chaque modification : compiler sans **aucun avertissement** (Sendable / MainActor compris),
  ajouter des tests, lancer les tests concernés, puis résumer le résultat en quelques lignes.
- Commits petits et explicites ; pousser sur `main` quand la modification est terminée et testée.
- Après chaque push sur `main` qui touche `Sources/` : mettre à jour l'application installée avec
  `scripts/package.sh --install` (sans demander), puis le signaler dans le résumé. Le script ferme
  l'app normalement (proposition d'enregistrer) ; si Emmanuel annule, l'installation est abandonnée.

## Construire et tester

Paquet Swift (swift-tools 5.9, macOS 14, mode de langage Swift 5), sans dépendance externe :

```sh
swift build                                   # compilation
swift test                                    # tous les tests (XCTest)
swift test --filter RotationPivotTests        # une classe de tests
swift run My2DCAD                             # lancer l'application
scripts/package.sh [--install]                # .app Release, .dmg et .pkg dans dist/ (--install : dans /Applications)
```

Xcode : ouvrir `Package.swift`, schéma « My2DCAD », ⌘R pour lancer, ⌘U pour les tests.

## Architecture

- SwiftUI + AppKit. `DocumentStore` (@MainActor, `.shared`) détient le document, la sélection,
  la vue (zoom, offset) et l'historique.
- **Modifications du document** : `perform { $0… }` (une étape d'annulation) ; pendant un geste,
  `beginTransaction()` / `commitTransaction()` et modification directe de `doc`.
  Le setter de `doc` appelle `resolveGlue(previous:)` (cotes collées aux formes).
- **Unités** : 1 unité du monde = 1 pt du papier ; la feuille occupe (0,0)–(w,h).
  Mesures affichées : `Diagram.measure(world)` (échelle 1:N et unité de la page comprises),
  inverse `worldLength(forMeasure:)`.
- **Validation** : tout document chargé ou modifié par l'assistant passe par `DiagramIO.validate`.
  Tout nouveau champ du modèle : `decodeIfPresent` avec valeur par défaut, et contrôle dans `validate`.
- Champs numériques du volet et du ruban : `NumericField` (NSTextField natif, validé à Entrée,
  Tab ou clic ailleurs ; Échap rétablit).

### Fichiers principaux (`Sources/My2DCAD/`)

| Fichier | Rôle |
|---|---|
| `Model.swift` | `Shape`, `Diagram`, `ShapeKind` |
| `DocumentStore.swift` | état, historique, outils, moniteur clavier/souris |
| `CanvasView.swift` | dessin du canevas, gestes (tracé, déplacement, poignées, rotation) |
| `Ribbon.swift` | ruban (Accueil, Insertion, Création, Affichage, Développeur), thème Visio |
| `InspectorView.swift` | volet « Format de la forme » |
| `Stencils.swift` | bibliothèques de formes (volet Formes), dont « Cotation » |
| `ShapeDrawing.swift` | tracé par cliquer-glisser (Maj : proportions, ⌥ : depuis le centre) |
| `Rotation.swift` | rotation de toutes les formes, groupes, point de rotation (`pin`, `groupPin`) |
| `Dimensions.swift` | cotes (linéaires, angulaires, rayon, diamètre) et collage aux formes |
| `ShapeOperations.swift` | Union, Combiner, Fragmenter, Intersection, Soustraire, Joindre, Rogner, Décalage, Ajuster la courbe |
| `Paths.swift` | traits, courbes, longueur des tracés |
| `Sheet.swift`, `Grid.swift`, `Rulers.swift` | feuille (A5–A2, personnalisée), grille métrique, échelle |
| `Assistant*.swift` | assistant IA (API Anthropic Messages, outils JSON, clé dans le Trousseau) |
| `Persistence.swift`, `Export.swift`, `SVG.swift` | fichiers, PDF/PNG/impression, SVG |
| `NumericField.swift` | champ numérique natif |

Tests : `Tests/My2DCADTests/My2DCADTests.swift` (une classe XCTest par fonction).

## Conventions d'interface

- Comportements de Visio : un simple clic ne crée jamais de forme (tracé par cliquer-glisser) ;
  l'outil reste actif après un tracé (Échap ou V pour revenir au pointeur) ; Maj : 15° / 45° /
  proportions ; ⌥ : depuis le centre ; la page est centrée au démarrage ; onglet Accueil au démarrage.
- Raccourcis d'outils : ⌘1 à ⌘8 seulement (⌘9 = Ajuster à la fenêtre).
- La barre d'état affiche une aide contextuelle selon l'outil et la sélection : la tenir à jour.
