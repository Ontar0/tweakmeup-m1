# tweakmeup-m1

Tweaks personales para macOS en **Apple Silicon (M1, 8 GB)**, en un solo script
idempotente y sin dependencias.

Es una reescritura moderna de [fedek/MacOSX-tips](https://github.com/fedek/MacOSX-tips)
(un script de la era Lion que en macOS actual está roto en varios lugares —
abajo está el detalle de qué se descartó y por qué).

- Solo usa `/bin/bash` (3.2, el que trae macOS) y `defaults`.
- **No** toca boot-args, **no** escribe en `/usr/bin`, **no** requiere desactivar SIP.
- Se puede correr las veces que quieras: los `defaults` se comparan antes de escribir
  y los dotfiles se actualizan dentro de bloques con marcadores.

## Uso

```sh
./tweakmeup.sh --dry-run     # ver qué haría (no escribe nada)
./tweakmeup.sh               # aplicar
./tweakmeup.sh --self-test   # pruebas internas (no toca tu sistema)
```

Con `make`:

```sh
make dry-run   # equivale a --dry-run
make apply     # aplica
make test      # self-test
```

### Opciones

| Flag | Qué hace |
| --- | --- |
| `-n`, `--dry-run` | Muestra el plan sin escribir nada. |
| `--show-hidden` | Muestra archivos ocultos en Finder y deja visible `~/Library`. |
| `--safari-dev` | Habilita el menú **Desarrollo** de Safari (cerrá Safari antes). |
| `--low-mem` | Ajustes pensados para 8 GB: menos animaciones/transparencia, Siri off. |
| `--firewall` | Enciende firewall + modo sigilo vía `socketfilterfw` (pide `sudo`). |
| `--no-spotlight` | Apaga el indexado de Spotlight vía `mdutil` (pide `sudo`). |
| `--no-restart` | No reinicia Finder/Dock/cfprefsd al terminar. |
| `--remove-blocks` | Saca los bloques de tweakmeup de tus dotfiles y sale. |
| `--self-test` | Corre las pruebas internas. |
| `-h`, `--help` | Ayuda. `--version` muestra la versión. |

## Qué hace

**Dotfiles** (dentro de bloques `# >>> tweakmeup-m1 >>>` … `# <<< tweakmeup-m1 <<<`):

- `~/.zshrc` (o `~/.bash_profile` si tu shell es bash): `brew shellenv` si Homebrew
  no está en el `PATH`, `CLICOLOR`, `EDITOR=vim` y unos alias (`ll`, `..`, `ql`, `preview`).
- `~/.ssh/config`: keepalives (`ServerAliveInterval`/`CountMax`) y `AddKeysToAgent`.
  Permisos `700/600`. **Sin `UseKeychain`**: es un parche de Apple que el OpenSSH de
  Homebrew no entiende y rompe *todas* las conexiones ssh con
  `Bad configuration option: usekeychain`.
- `~/.vimrc`: `syntax`, `mouse`, `ruler`, `showmatch`, `tabstop=4`, `shiftwidth=4`.
- `~/.gdbinit` solo si `gdb` está instalado.

**UX** (`defaults`, solo si el valor cambia):

- Finder: extensiones visibles, ruta completa en el título.
- `.DS_Store` desactivado en volúmenes de red.
- Dock: sin apps recientes.
- Capturas a `~/Pictures/Screenshots` en PNG y sin sombra.
- Teclado: repetición rápida (`KeyRepeat=2`, `InitialKeyRepeat=15`) y sin acento
  emergente al mantener la tecla.
- Paneles de guardar/imprimir expandidos. TextEdit en texto plano.

**`--low-mem`** (M1 8 GB):

- Animaciones del Dock y de ventanas al mínimo, sin transparencias.
- Siri desactivado.

Al terminar reinicia `Finder`, `Dock`, `SystemUIServer` y `cfprefsd` para que se aplique
(no hace falta cerrar sesión, salvo para `reduceTransparency` y Siri).

## Cómo revertir

- `./tweakmeup.sh --remove-blocks` para los dotfiles.
- Los `defaults`: `defaults delete <dominio> <clave>` (por ejemplo
  `defaults delete com.apple.dock show-recents`) o `defaults delete <dominio>` para
  borrar todo el dominio.
- Spotlight: `sudo mdutil -a -i on`.
- Firewall: Preferencias del Sistema → Red → Firewall, o
  `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off`.

## Qué del script original NO se copió (y por qué)

Verificado en macOS 26 / Apple Silicon:

| Del original | Problema | Qué hace este script |
| --- | --- | --- |
| `sudo ln -s .../airport /usr/bin/airport` | `airport` ya no existe (reemplazo: `wdutil`) y `/usr/bin` está protegido por SIP: falla aunque uses sudo. | No lo hace. |
| `sudo nvram boot-args="-v"` | En Apple Silicon no se puede escribir `boot-args` desde macOS (hay que ir a Recuperación). | No lo hace. |
| `echo "alias ql='qlmanage -p $*'"` | `$*` se expande **al escribir** el archivo: queda `alias ql='qlmanage -p '` y el alias pierde los argumentos. | `alias ql='qlmanage -p'` (los argumentos se pasan solos). |
| `echo "export EDITOR=vim"` | Faltaba el `>>`: nunca se guardaba. | Está en el bloque de `.zshrc`. |
| Escribir en `~/.profile` | macOS usa zsh (y bash lee `.bash_profile`), así que casi nada de eso se aplicaba. | Escribe en `.zshrc`/`.bash_profile` según tu shell. |
| `>>` a `.ssh/config`, `.vimrc`, `.gdbinit`… | No idempotente: cada corrida duplica todo. | Bloques con marcadores + `set_default` que compara antes de escribir. |
| `mkdir $HOME/.ssh` y `mkdir $HOME/screenshots` | Sin `-p` (falla si existe) y sin permisos. | `mkdir -p` y `chmod 700/600` en `.ssh`. |
| `sudo defaults write /Library/Preferences/com.apple.alf ...` + `--setblockall on` | Escribir el plist a mano lo pisa el daemon; "block all" rompe AirDrop, compartir archivos y servers locales. | `socketfilterfw` con `--setglobalstate on` y `--setstealthmode on`, sin `--setblockall`. |
| `QLEnableTextSelection`, `QLEnableXRayFolders`, `UseEncryptedSwap`, `AppleFontSmoothing`, `CrashReporter DialogType` | Claves de OS X antiguo: hoy son no-op. | Se omiten. |
| `launchctl load -w com.apple.locate.plist` | Comando legacy; hoy `mdfind` cubre la búsqueda. | Se omite. |
| `HiddenUsersList -array-add ard` | Oculta la cuenta `ard` del login. | Se omite. |
| `UseKeychain yes` (variantes que lo agregan) | Solo existe en el `ssh` de Apple; con el OpenSSH de Homebrew en el `PATH` falla con `Bad configuration option` y rompe **todo** ssh. | Se omite; queda `AddKeysToAgent yes`, que es estándar. |

También se omitió el bloque de firewall/IPFW (ipfw se eliminó en OS X 10.10) y no se
reinician procesos "a mano" con `killall` sueltos: se hace una sola vez al final.

## Licencia

MIT — ver [LICENSE](LICENSE).
