# ArtShot X Preview · 0.7.0

Capture d’écran, annotation et enregistrement local pour **macOS 14+ Apple Silicon** et **Windows 11 x64**. Interface en français, sans compte.

La migration partage le cœur Rust et l’interface React/Tauri. macOS conserve un adaptateur Swift natif ; Windows utilise ses propres moteurs de capture et d’audio. L’application Swift 0.6.2 reste disponible dans le dépôt.

## Installation

[Télécharger la preview 0.7.0](https://github.com/LeKibbitz/artshot-x/releases/tag/v0.7.0-preview.1) : les deux installateurs et leurs empreintes SHA-256 sont disponibles. Le DMG a été installé puis lancé sur Mac ; les essais sur Windows physique restent à réaliser.

- **macOS** : DMG Apple Silicon, signature ad-hoc, sans notarisation.
- **Windows** : installateur EXE x64 non signé ; WebView2 installé si nécessaire.

Voir le [guide d’installation](docs/install-preview.md). L’utilisation des installateurs ne nécessite ni terminal ni outils de développement.

Quitter l’ancienne application avant de lancer **ArtShot X Preview**, pour libérer les raccourcis. La preview utilise une identité et une bibliothèque séparées ; elle ne migre pas automatiquement les captures historiques.

## Fonctions implémentées

- Capture d’un écran ou d’une zone ajustable ; miniature avec actions et bibliothèque locale.
- Flèches, rectangles, étapes numérotées et annulation ; copie et export PNG à la résolution d’origine.
- Capture défilante verticale avec aperçu complet et rejet des alignements incertains.
- Vidéo d’écran ou de zone, caméra avec formes et zoom centré 1–3×, microphone et audio système séparés.
- Pause/reprise, télécommande flottante, clics et raccourcis ; suppression de passages, volumes indépendants et export MP4.
- Originaux conservés ; exports écrits dans une copie distincte.

| Action | macOS | Windows |
| --- | --- | --- |
| Écran | ⌘ ⌥ ⇧ 5 | Ctrl Alt Maj 5 |
| Zone | ⌘ ⌥ ⇧ 6 | Ctrl Alt Maj 6 |
| Préparation / télécommande | ⌘ ⌥ ⇧ 7 | Ctrl Alt Maj 7 |

Les commandes restent accessibles depuis l’icône de barre des menus ou de notification si un raccourci est occupé.

## État de validation

Les 21 tests Rust du workspace et les 4 tests des helpers frontend passent sur l’hôte de développement. Ils couvrent géométrie, annotations, défilement, coupes, protection des originaux et exports. Les algorithmes audio Windows ont aussi été testés séparément sur CPU. Des captures et exports natifs macOS ont été exercés pendant le développement.

**L’exécution sur Windows physique n’a pas été validée.** Installation, permissions, focus, plein écran, écrans multiples/DPI, caméra et synchronisation audiovisuelle nécessitent encore des essais des paquets distribués. Cette preview ne constitue pas une livraison finale validée sur les deux systèmes.

[Architecture et limites](docs/cross-platform.md) · [Construire les installateurs](docs/install-preview.md#construction-locale) · [Guide Swift historique](docs/legacy-swift.md)

## Licence

MIT pour ArtShot X. Les composants FFmpeg/FFprobe distribués sous Windows conservent leurs propres licences, incluses dans les ressources du paquet. ArtShot X est indépendant de CleanShot.
