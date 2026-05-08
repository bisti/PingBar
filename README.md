# PingBar

Petite app macOS de barre de menu qui affiche le ping actuel vers une cible.

Par defaut, la cible est `1.1.1.1`. Depuis le menu, vous pouvez changer la cible, configurer l'intervalle de ping, activer le lancement au demarrage, ou quitter l'app.

## Developpement

```sh
swift test
swift run PingBar
```

`swift run PingBar` lance l'app sans packaging. Elle apparait dans la barre de menu et se ferme depuis le menu `Quitter PingBar`.

L'option de lancement au demarrage doit etre testee depuis le bundle `PingBar.app`, car macOS demande une app signee.

## Creer l'app macOS

```sh
make package
open PingBar.app
```

Le bundle `PingBar.app` est configure avec `LSUIElement`, donc il n'affiche pas d'icone dans le Dock.
