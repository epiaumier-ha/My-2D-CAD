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
- **Pages** : onglets en bas du dessin (double-clic pour renommer, clic droit : dupliquer, déplacer, supprimer), menu Page, ⌥⌘N, ⌥⌘← / ⌥⌘→.
- **Calques** (par page) : visible, verrouillé, imprimable, calque actif pour les nouvelles formes ; choix du calque dans l'inspecteur.
- **Grouper / dissocier** (⌘G / ⇧⌘G) : un clic sélectionne tout le groupe.
- **Repères d'alignement dynamiques** (Affichage) : alignement des bords et des centres sur les autres formes pendant le déplacement, le dessin et le redimensionnement.
- **Export** : PDF vectoriel de toutes les pages (⌥⌘E), PNG haute résolution de la page (⇧⌥⌘E), impression (⌘P) ; calques masqués ou non imprimables exclus.
- **Règles et repères** : règles graduées dans l'unité de la page (mm, cm, m, in, pt) avec échelle 1:N ; glisser depuis une règle crée un repère (les formes s'y calent), le ramener sur la règle le supprime ; Affichage > Règles (⌥⌘R).
- **Cotes** (outil M) : cote linéaire avec lignes d'attache, flèches et mesure automatique (unité, échelle, décimales de la page) ; poignées pour les extrémités et le décalage.
- **Connecteurs** : tracé orthogonal qui contourne les formes, droit ou courbe (inspecteur, onglet Style ; défaut par page).
- **SVG** : export vectoriel de la page ; import (rect, cercle, ellipse, ligne, polyligne, polygone, path complet avec arcs, texte, groupes, transformations, styles) ajouté à la page sous forme d'un groupe.
- **Bloc de texte** (comme l'outil Bloc de texte de Visio) : poignée jaune pour placer le texte n'importe où (Maj : axe), poignées vertes pour sa largeur ; réglages précis dans l'onglet Texte ; un clic sur le texte sélectionne la forme.
- Formes : rectangle, ellipse, losange, texte (clic = taille par défaut, glisser = taille libre).
- Sélection (clic, Maj+clic, rectangle de sélection), déplacement, redimensionnement par les coins.
- Connecteurs orthogonaux collés aux points de connexion (haut/droite/bas/gauche) : ils suivent les formes.
- Grille avec magnétisme, zoom (pincement, ⌘/⌥ + molette, menu Affichage), déplacement de la vue (défilement ou outil Main).
- Inspecteur : texte, couleur, position et taille. Dupliquer (⌘D), supprimer (⌫), flèches pour décaler (⌥ = 1 unité).
- Copier (⌘C), couper (⌘X), coller (⌘V, décalage en escalier) : les connecteurs entre formes copiées suivent.
- Rotation : poignée ronde au-dessus de la forme (Maj = pas de 15°), champ « Rotation » de l'inspecteur, ⌃R / ⌃L pour ±90°.
- Menu **Disposition** et inspecteur : aligner (gauche, centre, droite, haut, milieu, bas) et répartir horizontalement/verticalement.
- Annuler/rétablir (100 niveaux), enregistrement/ouverture JSON (.cad2d, format v2 multipage ; les fichiers v1 restent lisibles) avec validation stricte du fichier.

## Architecture
- `Model.swift` : données (Shape, Connector, Diagram), indépendantes du rendu.
- `Geometry.swift` : rotation, hit-test, points de connexion, routage.
- `ShapeLibrary.swift` : tracés vectoriels de chaque type de forme.
- `TextStyle.swift` : mise en forme du texte.
- `StatusBar.swift` / `WindowCloseGuard.swift` : barre d'état, confirmation à la fermeture de la fenêtre.
- `Rendering.swift` : dessin d'une page, partagé par le canevas et l'export.
- `Export.swift` : PDF, PNG, impression.
- `PagesLayersGroups.swift` / `PageBar.swift` : pages, calques, groupes et leur interface.
- `Units.swift` / `Rulers.swift` : unités, règles, repères.
- `Routing.swift` : connecteurs (A* qui contourne les formes, courbes).
- `SVG.swift` : export et import SVG.
- `TextBlock.swift` : position et largeur du bloc de texte.
- `Guides.swift` : repères d'alignement.
- `LineStyle.swift` : attributs de trait et leur rendu.
- `Paths.swift` : traits et courbes (points, échantillonnage, sélection).
- `Stencils.swift` : catalogue des bibliothèques et panneau latéral.
- `Arrange.swift` : presse-papiers, alignement, répartition, rotation de la sélection.
- `Persistence.swift` : E/S JSON + validation (limites de taille, valeurs finies, références).
- `DocumentStore.swift` : état, historique, vue, fichiers, clavier/molette.
- `CanvasView.swift` / `InspectorView.swift` / `App.swift` : interface.
