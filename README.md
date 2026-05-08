# PingBar

Petite app macOS de barre de menu qui affiche le ping actuel vers une cible.

Par defaut, la cible est `1.1.1.1`. Depuis le menu, vous pouvez rafraichir la mesure, changer la cible, ou quitter l'app.

La barre de menu affiche une icone et une couleur selon l'etat du ping: vert pour une bonne latence, orange pour une latence moyenne, rouge pour une latence elevee ou une erreur.

## Developpement

```sh
swift test
swift run PingBar
```

`swift run PingBar` lance l'app sans packaging. Elle apparait dans la barre de menu et se ferme depuis le menu `Quitter PingBar`.

## Creer l'app macOS

```sh
make package
open PingBar.app
```

Le bundle `PingBar.app` est configure avec `LSUIElement`, donc il n'affiche pas d'icone dans le Dock.
