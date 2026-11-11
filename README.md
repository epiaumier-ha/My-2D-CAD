# My2DCAD — prototype

Application de dessin 2D inspirée de Microsoft Visio (macOS 14+, Swift 5.9, SwiftUI + AppKit, aucune dépendance).

## Lancer
- Xcode : `File > Open…` puis choisir ce dossier (ou `xed .` dans le terminal), schéma **My2DCAD**, puis ⌘R.
- Tests : ⌘U dans Xcode, ou `swift test`.

## Fonctions
- **Bibliothèques de formes** (panneau de gauche, recherche, glisser-déposer ou clic) :
  organigramme (13 formes), réseau (9 icônes), électricité (11 symboles IEC).
- **Texte sur place** : double-clic sur une forme (ou Entrée / F2), Entrée pour valider, ⌥Entrée pour une nouvelle ligne, Échap pour annuler. Le texte revient à la ligne dans la forme.
- **Traits et courbes** : outils Trait (Maj = 45°) et Courbe (Bézier, poignée ronde pour la courbure) ; extrémités déplaçables, couleur du trait dans l'inspecteur.
- **Attributs de trait** (section « Trait » de l'inspecteur, appliqués à toute la sélection) : couleur, motif (continu, tirets, pointillés, tiret-point, tirets longs, aucun), épaisseur (0,25 à 8 pt), transparence, extrémités, flèches de début et de fin (ouverte, pleine, cercle, losange) et leur taille, pour les formes, traits, courbes et connecteurs.
- **Interface** : outils groupés façon Visio (Pointeur V, Main H, Connecteur C, Texte T, menu Dessin : R, E, D, L, B) ; l'outil reste actif après un dessin (Échap ou V pour revenir à la sélection) ; zoom en % dans la barre d'outils ; barre d'état (outil, position, sélection, zoom).
- **Inspecteur à onglets** : Forme, Style (remplissage : aucun, couleur, transparence ; trait), Texte (taille, couleur, gras, italique, alignement), Organiser (aligner, répartir, pivoter, ordre).
- **Ordre de superposition** (⇧⌘] premier plan, ⌘] avancer, ⌘[ reculer, ⇧⌘[ arrière-plan) et **menu contextuel** (clic droit).
- **Connecteurs** : extrémités déplaçables vers une autre forme, inversion du sens.
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
- `TextStyle.swift` : mise en forme du texte.
- `StatusBar.swift` / `WindowCloseGuard.swift` : barre d'état, confirmation à la fermeture de la fenêtre.
- `LineStyle.swift` : attributs de trait et leur rendu.
- `Paths.swift` : traits et courbes (points, échantillonnage, sélection).
- `Stencils.swift` : catalogue des bibliothèques et panneau latéral.
- `Arrange.swift` : presse-papiers, alignement, répartition, rotation de la sélection.
- `Persistence.swift` : E/S JSON + validation (limites de taille, valeurs finies, références).
- `DocumentStore.swift` : état, historique, vue, fichiers, clavier/molette.
- `CanvasView.swift` / `InspectorView.swift` / `App.swift` : interface.
