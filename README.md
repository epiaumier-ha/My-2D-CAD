# My2DCAD — prototype

Application de dessin 2D inspirée de Microsoft Visio (macOS 14+, Swift 5.9, SwiftUI + AppKit, aucune dépendance).

## Lancer
- Xcode : `File > Open…` puis choisir ce dossier (ou `xed .` dans le terminal), schéma **My2DCAD**, puis ⌘R.
- Tests : ⌘U dans Xcode, ou `swift test`.

## Fonctions
- **Bibliothèques de formes** (panneau de gauche, recherche, glisser-déposer ou clic) :
  organigramme (13 formes), réseau (9 icônes), électricité (11 symboles IEC).
- Formes : rectangle, ellipse, losange, texte (clic = taille par défaut, glisser = taille libre).
- Sélection (clic, Maj+clic, rectangle de sélection), déplacement, redimensionnement par les coins.
- Connecteurs orthogonaux collés aux points de connexion (haut/droite/bas/gauche) : ils suivent les formes.
- Grille avec magnétisme, zoom (pincement, ⌘/⌥ + molette, menu Affichage), déplacement de la vue (défilement ou outil Main).
- Inspecteur : texte, couleur, position et taille. Dupliquer (⌘D), supprimer (⌫), flèches pour décaler (⌥ = 1 unité).
- Copier (⌘C), couper (⌘X), coller (⌘V, décalage en escalier) : les connecteurs entre formes copiées suivent.
- Rotation : poignée ronde au-dessus de la forme (Maj = pas de 15°), champ « Rotation » de l'inspecteur, ⌃R / ⌃L pour ±90°.
- Menu **Disposition** et inspecteur : aligner (gauche, centre, droite, haut, milieu, bas) et répartir horizontalement/verticalement.
- Annuler/rétablir (100 niveaux), enregistrement/ouverture JSON (.cad2d) avec validation stricte du fichier.

## Architecture
- `Model.swift` : données (Shape, Connector, Diagram), indépendantes du rendu.
- `Geometry.swift` : rotation, hit-test, points de connexion, routage.
- `ShapeLibrary.swift` : tracés vectoriels de chaque type de forme.
- `Stencils.swift` : catalogue des bibliothèques et panneau latéral.
- `Arrange.swift` : presse-papiers, alignement, répartition, rotation de la sélection.
- `Persistence.swift` : E/S JSON + validation (limites de taille, valeurs finies, références).
- `DocumentStore.swift` : état, historique, vue, fichiers, clavier/molette.
- `CanvasView.swift` / `InspectorView.swift` / `App.swift` : interface.
