# Migration partagée · 0.7.0 Preview

État au 18 octobre 2026. Cibles : macOS 14+ Apple Silicon et Windows 11 x64. Windows 10 et Linux sont hors de ce jalon.

Le code partagé et les adaptateurs sont implémentés. Les installateurs DMG et EXE sont construits et distribués dans [v0.7.0-preview.1](https://github.com/LeKibbitz/artshot-x/releases/tag/v0.7.0-preview.1). Aucune validation d’exécution sur Windows physique n’a été réalisée dans cette session. Une compilation et des tests de logique ne prouvent pas le fonctionnement d’un bureau Windows interactif.

## Architecture effectivement utilisée

| Couche | Implémentation |
| --- | --- |
| Domaine et traitement partagé | `crates/artshot-core` : géométrie en pixels physiques avec origine en haut à gauche, modèles serde, annotations, alignement vertical, cadrage caméra et calcul des coupes/pauses. |
| Interface, bibliothèque, réglages | `desktop/` : React/TypeScript et Tauri 2 ; commandes Rust locales. |
| macOS | Adaptateur Swift livré avec la preview : ScreenCaptureKit, AVFoundation et AppKit pour capture, pistes indépendantes, caméra et export MP4. Panneaux natifs et intégration Tauri pour les fenêtres transitoires. |
| Windows — images | Capture native via `xcap`, coordonnées physiques et validation des zones. |
| Windows — vidéo/caméra | FFmpeg embarqué : GDI `gdigrab` pour l’écran, DirectShow pour la caméra ; segments séparés pendant les pauses et assemblage avant export. **Cette preview n’utilise pas Windows Graphics Capture pour enregistrer la vidéo.** |
| Windows — audio | WASAPI natif : loopback du périphérique de sortie par défaut et microphone par défaut, dans deux WAV indépendants. Aucun périphérique Stereo Mix ou pilote virtuel requis. |
| Stockage | Fichiers locaux, index de bibliothèque, manifestes de projet et originaux séparés des exports. Identité preview `org.artshotx.desktop`. |
| Distribution | DMG macOS et EXE NSIS Windows ; dépendances d’exécution incluses ou prises en charge par l’installateur. |

Les images et vidéos de capture restent dans des fichiers ou buffers natifs. Le flux vidéo n’est pas transporté en JSON. Les aperçus locaux utilisent le protocole d’assets de l’application ; l’éditeur peut transmettre un PNG annoté pour la copie ou l’export.

Le code Swift historique dans `Sources/` et ses scripts de test sont conservés. La preview ne remplace pas l’application installée et n’importe pas automatiquement sa bibliothèque. Voir le [guide historique](legacy-swift.md).

## Fonctions présentes

La preview implémente la sélection ajustable, les captures plein écran/zone, les miniatures, la bibliothèque, les annotations PNG avec annulation et le défilement vertical. L’alignement partagé conserve les fixtures Swift : déplacements descendants, en-tête fixe, texte clairsemé et rejet des pieds de page fixes, mouvements inverses ou motifs ambigus.

Les adaptateurs implémentent vidéo d’écran/zone, caméra avec forme/position/zoom, microphone, audio système, pause/reprise et événements de clics/raccourcis. L’éditeur propose retrait de passages, activation des sources/effets disponibles, gains indépendants, aperçu de montage et MP4. Une source absente à la capture ne peut pas être ajoutée ensuite. Les annotations et choix de montage de l’éditeur restent locaux à la session ; les exports contiennent les modifications appliquées.

Les exports protègent les originaux, aperçus et pistes audio de la bibliothèque, y compris les alias symboliques et liens physiques. Le résultat est produit dans un fichier temporaire voisin puis remplacé après réussite. Un échec d’export conserve le fichier de destination précédent. Les projets vidéo conservent des manifestes de récupération avant l’assemblage et la création de l’aperçu.

## Discipline temporelle Windows

Les WAV utilisent les horodatages QPC de WASAPI. Une même observation de progression FFmpeg ancre les deux pistes audio dans la timeline vidéo. Le temps des images déjà encodées est conservé au début de chaque segment ; après fermeture du segment, sa durée mesurée recale les WAV par silence ou troncature. La reprise utilise cette durée cumulée. Les callbacks audio tardifs sont filtrés selon les intervalles historiques.

Des tests CPU couvrent ces transformations, le démarrage retardé, plusieurs reprises et la réouverture des WAV tronqués. Ils ne mesurent pas la latence du matériel, de l’encodeur ou du canal de progression FFmpeg. La précision audiovisuelle finale et la synchronisation caméra/écran restent à mesurer sur Windows réel, avant et après plusieurs pauses et coupes.

## Preuves disponibles et limites

Exécution locale : `cargo test --workspace` — 21 tests réussis (cœur 10, desktop 8, plateforme 3) ; helpers frontend — 4 tests réussis. Ces résultats concernent l’hôte macOS.

| Vérification | État |
| --- | --- |
| Cœur Rust et helpers TypeScript | Tests locaux exécutés : géométrie, annotations, fixtures de défilement, coupes et conservation des dimensions. |
| Backend/export | Tests locaux exécutés : réglages avant démarrage, échec de sauvegarde du défilement, JSON atomique, protection des originaux/alias et conservation d’un export existant en cas d’échec. |
| Audio Windows | Compilation Windows et Clippy effectués ; algorithmes CPU extraits sans modification et testés sur l’hôte macOS. Les appels WASAPI n’ont pas été exécutés sur Windows. |
| Adaptateur macOS | Essais de capture PNG et d’enregistrement avec pause/reprise puis export MP4 pendant le développement. Ils ne constituent pas une validation du DMG final. |
| Paquets | DMG vérifié, monté, installé puis lancé sur Mac Apple Silicon. EXE NSIS x64 construit depuis les sources finales ; architecture, dépendances et garde Windows 11 inspectées. Installation Windows, mises à niveau et désinstallation restent à vérifier. |
| CI GitHub | Workflow préparé dans [docs/ci/desktop-preview.yml](ci/desktop-preview.yml), mais non activé dans `.github/workflows` : les identifiants disponibles n’autorisent pas sa publication. Aucun succès de CI Windows n’est revendiqué. |

## Acceptation restante

- Télécharger, installer, lancer et désinstaller les paquets finaux ; vérifier une mise à niveau sans perte de captures ni réglages.
- Vérifier les autorisations écran/caméra/microphone, l’accessibilité pour les événements, les erreurs et les raccourcis sur les claviers utilisés.
- Mesurer le maintien du focus et du contexte plein écran, les fenêtres non activantes et leur exclusion des captures.
- Tester plusieurs écrans, origines négatives, DPI différents, sélection et dimensions physiques exportées.
- Tester le défilement réel et ses coutures, la caméra, les deux sources audio, plusieurs pauses/reprises et les coupes après export.
- Faire réaliser ces essais Windows 11 par des testeurs externes et consigner système, matériel, écrans et sources activées.

La livraison finale exige des installateurs téléchargeables, utilisables sans outils de développement, leurs empreintes et des résultats d’acceptation sur les deux systèmes. La signature macOS est ad-hoc, sans notarisation ; le paquet Windows est non signé. Ces statuts doivent rester visibles dans les notes de release.
