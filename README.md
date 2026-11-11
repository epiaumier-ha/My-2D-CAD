# My2DCAD — prototype

Application de dessin 2D inspirée de Microsoft Visio (macOS 14+, Swift 5.9, SwiftUI + AppKit, aucune dépendance).

## Lancer
- Xcode : `File > Open…` puis choisir ce dossier (ou `xed .` dans le terminal), schéma **My2DCAD**, puis ⌘R.
- Tests : ⌘U dans Xcode, ou `swift test`.

## Fonctions
- Formes : rectangle, ellipse, losange, texte (clic = taille par défaut, glisser = taille libre).
- Sélection (clic, Maj+clic, rectangle de sélection), déplacement, redimensionnement par les coins.
- Connecteurs orthogonaux collés aux points de connexion (haut/droite/bas/gauche) : ils suivent les formes.
- Grille avec magnétisme, zoom (pincement, ⌘/⌥ + molette, menu Affichage), déplacement de la vue (défilement ou outil Main).
- Inspecteur : texte, couleur, position et taille. Dupliquer (⌘D), supprimer (⌫), flèches pour décaler (⌥ = 1 unité).
- Annuler/rétablir (100 niveaux), enregistrement/ouverture JSON (.cad2d) avec validation stricte du fichier.

## Architecture
- `Model.swift` : données (Shape, Connector, Diagram), indépendantes du rendu.
- `Geometry.swift` : hit-test, points de connexion, routage.
- `Persistence.swift` : E/S JSON + validation (limites de taille, valeurs finies, références).
- `DocumentStore.swift` : état, historique, vue, fichiers, clavier/molette.
- `CanvasView.swift` / `InspectorView.swift` / `App.swift` : interface.
