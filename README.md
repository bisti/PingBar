# PingBar

Petite app macOS de barre de menu qui affiche le ping actuel vers une cible.

Par defaut, la cible est `1.1.1.1`. Depuis le menu, vous pouvez changer la cible, configurer l'intervalle de ping, ou quitter l'app.

Les intervalles sont volontairement approximatifs: l'app laisse macOS grouper les reveils du timer pour limiter l'impact batterie.

## Developpement

```sh
swift test
swift run PingBar
```

`swift run PingBar` lance l'app sans packaging. Elle apparait dans la barre de menu et se ferme depuis le menu `Quitter`.

## Creer l'app macOS

```sh
make package
open PingBar.app
```

Le bundle `PingBar.app` est configure avec `LSUIElement`, donc il n'affiche pas d'icone dans le Dock.
