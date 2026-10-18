# ArtShot X Preview · application partagée

Interface React/TypeScript et hôte Tauri 2 de la preview 0.7.0. Cœur partagé dans `../crates/artshot-core`, adaptateurs natifs dans `../crates/artshot-platform`.

[Installation, signatures et packaging](../docs/install-preview.md) · [Architecture et état de validation](../docs/cross-platform.md) · [Guide utilisateur](../README.md)

## Développement

Prérequis : Node.js 22, Rust stable et outils de compilation de la plateforme. Depuis ce dossier :

```sh
npm ci
npm run tauri -- dev
```

Tauri prépare l’adaptateur natif et lance Vite. `npm run dev` seul lance uniquement le frontend ; les commandes de capture nécessitent l’hôte Tauri.

```sh
npm test
npm run build
```

Ces commandes testent les helpers puis vérifient TypeScript et produisent le frontend. Depuis la racine du dépôt, `cargo test --workspace` teste le code Rust.

## Installateurs

Sur macOS Apple Silicon, depuis la racine du dépôt :

```sh
node desktop/scripts/package-macos.mjs
```

Le script construit l’application, applique et vérifie la signature ad-hoc, crée le DMG sans automatisation Finder et affiche son SHA-256. `--skip-build` réutilise un bundle final déjà construit. La signature n’est pas une notarisation.

Sous Windows, depuis ce dossier :

```sh
npm run tauri -- build --target x86_64-pc-windows-msvc --bundles nsis
```

La [construction croisée depuis macOS](../docs/install-preview.md#compiler-windows-depuis-macos) est documentée séparément. Les tests matériels et d’installation Windows restent nécessaires ; construire un EXE ne les remplace pas.
