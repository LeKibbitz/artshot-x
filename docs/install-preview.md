# Installer ArtShot X Preview · 0.7.1

Cibles : **macOS 14+ Apple Silicon** et **Windows 11 x64**.

[Télécharger v0.7.1-preview.1](https://github.com/LeKibbitz/artshot-x/releases/tag/v0.7.1-preview.1). Les deux installateurs ont été construits localement et sont joints à la release avec leurs empreintes. Le DMG a été monté, vérifié, installé puis lancé sur Mac Apple Silicon. La compilation Windows ne constitue pas un essai d’installation ou d’exécution sur Windows réel.

## Avant de commencer

Quitter l’application Swift historique pour libérer les raccourcis. La preview s’appelle **ArtShot X Preview**, avec l’identité `org.artshotx.desktop` et un stockage séparé. Elle ne remplace pas l’ancienne application et ne migre pas automatiquement ses captures.

L’utilisation normale ne nécessite ni terminal, ni Rust, ni Node.js, ni Xcode. Les instructions de compilation plus bas concernent les développeurs.

## macOS Apple Silicon

1. Ouvrir le DMG et déplacer **ArtShot X Preview** dans Applications.
2. Lancer l’application. Son icône apparaît dans la barre des menus ; utiliser cette icône ou ⌘ ⌥ ⇧ 7 pour préparer une capture.
3. Autoriser l’enregistrement de l’écran dans Réglages Système → Confidentialité et sécurité. Relancer si macOS le demande.
4. Autoriser caméra et microphone lors de leur utilisation. Les indicateurs de clics/raccourcis nécessitent l’autorisation Accessibilité.

**Signature ad-hoc, sans Developer ID ni notarisation.** macOS peut bloquer la première ouverture. Après la tentative de lancement, utiliser l’autorisation d’ouverture proposée dans Réglages Système → Confidentialité et sécurité, uniquement pour le paquet téléchargé depuis la release du projet. Aucune suppression de quarantaine par terminal n’est requise.

Le paquet contient l’adaptateur Swift ; capture et export utilisent les frameworks Apple. FFmpeg n’est pas embarqué sur macOS. Les permissions de l’ancienne application ne valent pas automatiquement pour cette nouvelle identité.

## Windows 11 x64

1. Lancer l’installateur EXE NSIS. Windows 11 build 22000 minimum est vérifié avant installation.
2. Suivre l’installation pour l’utilisateur courant. L’installateur prend en charge WebView2 ; une connexion Internet peut être nécessaire si ce runtime manque.
3. Lancer **ArtShot X Preview** et utiliser l’icône de notification ou Ctrl Alt Maj 7.
4. Vérifier les autorisations de caméra et de microphone dans les paramètres de confidentialité Windows si une source est refusée.

**Installateur non signé.** SmartScreen peut signaler un éditeur inconnu. Vérifier l’origine du fichier et son empreinte publiée ; ne pas désactiver la protection Windows globalement.

FFmpeg et FFprobe sont embarqués. La vidéo utilise GDI/DirectShow ; l’audio système utilise WASAPI loopback, avec le microphone dans une piste séparée. Aucun Stereo Mix ou pilote virtuel n’est nécessaire.

L’exécution, les permissions, le focus, le plein écran, les écrans multiples et la synchronisation audiovisuelle restent à valider par des testeurs sur une machine Windows 11 physique.

## Premier essai

Capturer une petite zone, l’ouvrir dans l’éditeur, ajouter une flèche puis exporter un PNG. Vérifier ses dimensions et retrouver l’original dans la bibliothèque. Tester ensuite un court enregistrement avec chaque source audio séparément, puis une pause/reprise et un export MP4.

En cas de raccourci occupé, fermer les autres versions d’ArtShot X ; les commandes de l’icône restent disponibles. Conserver le texte exact de toute erreur avec la version du système, le nombre d’écrans et les sources sélectionnées.

### Raccourcis et autorisation macOS

Les raccourcis ne sont actifs que lorsque **ArtShot X Preview** tourne : son icône doit être présente dans la barre des menus. Fermer la bibliothèque laisse l’application en arrière-plan ; la commande Quitter désactive les raccourcis. Cette preview ne démarre pas automatiquement à l’ouverture de session.

Si l’interrupteur d’autorisation est activé mais que la capture est refusée après un remplacement de build, macOS peut conserver la signature d’une ancienne preview. Quitter Preview, retirer uniquement son entrée dans **Enregistrement de l’écran et des sons du système**, puis la réajouter avec le bouton `+` en sélectionnant l’application réellement installée dans Applications. Autoriser et relancer Preview. La rubrique **Enregistrement des sons du système uniquement** ne donne pas accès à l’image de l’écran.

Conserver une seule copie installée de Preview. La version Swift historique porte un autre nom et une autre autorisation ; ses réglages ne réparent pas ceux de Preview.

## Construction locale

Prérequis développeur : Node.js 22, Rust stable et outils de compilation natifs. macOS demande Xcode Command Line Tools et le SDK macOS approprié. Windows demande Visual Studio Build Tools, les outils C++ et le SDK Windows.

Depuis la racine du dépôt, sur macOS Apple Silicon :

```sh
cd desktop
npm ci
npm test
npm run build
cd ..
cargo test --workspace
node desktop/scripts/package-macos.mjs
```

`package-macos.mjs` construit le bundle `.app`, signe l’adaptateur et l’application en ad-hoc, vérifie les signatures, puis crée et vérifie le DMG directement avec `hdiutil`. Il évite l’étape de présentation Finder/AppleScript et affiche l’empreinte SHA-256. Le résultat est écrit dans `dist/ArtShot-X-0.7.1-macOS-arm64.dmg` sur Apple Silicon.

Après un build final déjà terminé, réutiliser son bundle sans recompiler :

```sh
node desktop/scripts/package-macos.mjs --skip-build
```

Sous Windows, depuis `desktop/`, utiliser `npm run tauri -- build --target x86_64-pc-windows-msvc --bundles nsis`. Tauri prépare les ressources natives et le frontend avant le packaging. `cargo test --workspace` exécute les tests Rust de l’hôte ; il ne lance pas les appels matériels Windows sur macOS.

Le script `prepare:native` compile l’adaptateur Swift sur macOS. Sous Windows, il prépare FFmpeg depuis `ffmpeg-static` 5.2.0, release b6.0, et FFprobe depuis `ffprobe-static` 3.1.0, basé sur FFmpeg 4.0.2. Licences effectives, configurations, sources et empreintes sont conservées dans les ressources. Les binaires `--enable-nonfree` sont refusés. Un remplacement via `ARTSHOT_FFMPEG_PATH` exige la documentation de ses sources exactes et de sa compilation dans `resources/licenses/external-source-info.txt`.

### Compiler Windows depuis macOS

LLVM, NSIS et `cargo-xwin` permettent la construction croisée. Aucun exécutable Windows n’est lancé par cette préparation.

```sh
brew install llvm nsis
cargo install --locked cargo-xwin
rustup target add x86_64-pc-windows-msvc
cd desktop
npm run prepare:windows
PATH="/opt/homebrew/opt/llvm/bin:$PATH" npm run tauri -- build --runner cargo-xwin --target x86_64-pc-windows-msvc --bundles nsis --config src-tauri/tauri.windows-cross.conf.json
```

Les ressources Windows restent séparées dans `resources/windows/`. Le téléchargement FFmpeg b6.0 est verrouillé par SHA-256 ; les configurations PE sont inspectées et les licences accompagnent le paquet. Cette construction ne valide ni l’installation ni les périphériques Windows.

## CI et publication

Le workflow [Desktop preview installers](ci/desktop-preview.yml) est versionné dans `docs/ci/desktop-preview.yml`. Il doit être installé dans `.github/workflows/desktop-preview.yml` avec des identifiants autorisant cette écriture. Ceux de cette session ne le permettent pas ; aucun workflow GitHub actif ou build CI réussi n’est revendiqué.

Une fois activé, le workflow prévoit des tests natifs, un DMG Apple Silicon et un EXE NSIS x64, avec publication preview sur tag après réussite des deux builds. Les paquets de cette session sont construits localement. Le contrôle final porte sur les fichiers effectivement publiés, leur signature annoncée et leur installation réelle.
