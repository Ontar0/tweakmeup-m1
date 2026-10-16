#!/usr/bin/env bash
#
# tweakmeup-m1 — tweaks personales para macOS en Apple Silicon (M1, 8 GB)
#
# Reescritura moderna e idempotente de https://github.com/fedek/MacOSX-tips
# (aquel script era de la era Lion y en macOS moderno estaba roto: ver README).
#
#   ./tweakmeup.sh --dry-run    # muestra qué haría, sin tocar nada
#   ./tweakmeup.sh              # aplica
#
# Compatible con el bash 3.2 que trae macOS (/bin/bash). Sin dependencias.

set -euo pipefail

VERSION="1.0.0"

MARK_BEGIN="# >>> tweakmeup-m1 >>>"
MARK_END="# <<< tweakmeup-m1 <<<"
SELFTEST_DOMAIN="me.tweakmeup.selftest"

# ---------------------------------------------------------------------------
# Estado / flags
# ---------------------------------------------------------------------------
DRY_RUN=0
DOTS_ONLY=0
WITH_LOW_MEM=0
WITH_FIREWALL=0
NO_SPOTLIGHT=0
SHOW_HIDDEN=0
SAFARI_DEV=0
NO_RESTART=0
REMOVE_BLOCKS=0
SELF_TEST=0
FILE_ROOT="${TWEAKMEUP_ROOT:-}"   # prefijo para tests (vacío en uso real)

CHANGED=0
PLANNED=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[0;32m'; C_GREY=$'\033[0;90m'
  C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_GREY=""; C_YELLOW=""; C_RED=""; C_RESET=""
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
note() { printf '  %s·%s %s\n' "$C_GREY" "$C_RESET" "$*"; }
skip() { printf '  %s·%s %s\n' "$C_GREY" "$C_RESET" "$*"; }
ok()   { CHANGED=$((CHANGED + 1)); printf '  %s+%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
tweakmeup-m1 — tweaks idempotentes para macOS en Apple Silicon (M1, 8 GB)

Uso: ./tweakmeup.sh [opciones]

Opciones seguras (por defecto):
  -n, --dry-run        Muestra qué haría, sin escribir nada.
      --show-hidden    Además muestra archivos ocultos y ~/Library.
      --safari-dev     Habilita el menú Desarrollo de Safari (cerrá Safari antes).
      --dots-only      Solo toca los dotfiles (~/.zshrc, ~/.ssh/config, ~/.vimrc).
      --no-restart     No reinicia Finder/Dock/cfprefsd al terminar.
      --remove-blocks  Quita los bloques de tweakmeup de tus dotfiles y sale.

Opciones que tocan el sistema (opt-in explícito):
      --low-mem        Ajustes para 8 GB: menos animaciones/transparencia, Siri off.
      --firewall       Enciende el firewall y modo sigilo (socketfilterfw, con sudo).
      --no-spotlight   Apaga el indexado de Spotlight (mdutil, con sudo, reversibles).

Otros:
  -h, --help           Esta ayuda.
      --version        Versión.
      --self-test      Corre las pruebas internas (no toca tu sistema).

Nada de lo que hace requiere desactivar SIP, y no toca boot-args ni /usr/bin.
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# run_sudo <cmd...>  — ejecuta (o simula) un comando con sudo
run_sudo() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s sudo %s\n' "$C_GREY" "$C_RESET" "$*"
    PLANNED=$((PLANNED + 1))
  else
    sudo "$@"
  fi
}

sudo_ready() {
  [ "$(id -u)" = 0 ] && return 0
  sudo -n true 2>/dev/null
}

has_sudo() {
  if [ "$DRY_RUN" = 1 ]; then
    return 0
  fi
  if [ "$(id -u)" = 0 ]; then
    warn "estás como root: preferí correrlo con tu usuario y dejar que pida sudo."
    return 0
  fi
  if ! sudo_ready; then
    warn "hace falta sudo sin contraseña en caché: corré 'sudo -v' y reintentá, o pasá sudo al script."
    return 1
  fi
  return 0
}

# set_default <domain> <key> <type> <value> — solo escribe si el valor cambia
set_default() {
  local domain="$1" key="$2" type="$3" value="$4" want have
  case "$type" in
    -bool) case "$value" in true|1|YES|yes) want=1 ;; *) want=0 ;; esac ;;
    *)     want="$value" ;;
  esac

  have="$(defaults read "$domain" "$key" 2>/dev/null || true)"

  if [ "$have" = "$want" ]; then
    skip "$domain $key ya vale $want"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s %s %s = %s (ahora: %s)\n' \
      "$C_GREY" "$C_RESET" "$domain" "$key" "$value" "${have:-<sin definir>}"
    PLANNED=$((PLANNED + 1))
    return 0
  fi

  defaults write "$domain" "$key" "$type" "$value"
  ok "$domain $key = $value"
}

# ensure_dir <dir>
ensure_dir() {
  local dir="$1"
  if [ -d "$dir" ]; then
    skip "$dir ya existe"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s mkdir -p %s\n' "$C_GREY" "$C_RESET" "$dir"
    PLANNED=$((PLANNED + 1))
    return 0
  fi
  mkdir -p "$dir"
  ok "creado $dir"
}

# --- bloques idempotentes en archivos de texto ------------------------------

strip_block() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { inblock = 1; next }
    $0 == e { inblock = 0; next }
    inblock != 1 { print }
  ' "$file"
}

trim_trailing_blank() {
  awk 'BEGIN { n = 0 }
       { line[n++] = $0 }
       END { while (n > 0 && line[n-1] == "") n--
             for (i = 0; i < n; i++) print line[i] }' "$1"
}

# write_block <path> <contenido> — reemplaza el bloque propio, conserva lo tuyo
write_block() {
  local file="$1" content="$2" path tmp out
  path="${FILE_ROOT}${file}"

  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s bloque en %s\n' "$C_GREY" "$C_RESET" "$path"
    PLANNED=$((PLANNED + 1))
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp -t tweakmeup)" || die "no pude crear temporal"
  out="$(mktemp -t tweakmeup)" || die "no pude crear temporal"

  strip_block "$path" > "$tmp"
  trim_trailing_blank "$tmp" > "$out"
  if [ -s "$out" ]; then printf '\n' >> "$out"; fi
  {
    printf '%s\n' "$MARK_BEGIN"
    printf '%s\n' "$content"
    printf '%s\n' "$MARK_END"
  } >> "$out"

  # cat > conserva permisos del archivo existente
  if [ -f "$path" ] && cmp -s "$out" "$path"; then
    skip "sin cambios: $path"
  else
    cat "$out" > "$path"
    ok "actualizado: $path"
  fi
  rm -f "$tmp" "$out"
}

# remove_block <path>
remove_block() {
  local file="$1" path tmp out
  path="${FILE_ROOT}${file}"

  if [ ! -f "$path" ]; then
    skip "no existe: $path"
    return 0
  fi
  if ! grep -qF "$MARK_BEGIN" "$path" 2>/dev/null; then
    skip "sin bloque propio: $path"
    return 0
  fi
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s quitar bloque de %s\n' "$C_GREY" "$C_RESET" "$path"
    PLANNED=$((PLANNED + 1))
    return 0
  fi

  tmp="$(mktemp -t tweakmeup)"; out="$(mktemp -t tweakmeup)"
  strip_block "$path" > "$tmp"
  trim_trailing_blank "$tmp" > "$out"
  if [ -s "$out" ]; then printf '\n' >> "$out"; fi
  cat "$out" > "$path"
  ok "bloque quitado: $path"
  rm -f "$tmp" "$out"
}

# ---------------------------------------------------------------------------
# Contenido de los dotfiles
# ---------------------------------------------------------------------------
BLOCK_SHELL="$(cat <<'EOF'
# Homebrew (Apple Silicon: /opt/homebrew; Intel: /usr/local)
if ! command -v brew >/dev/null 2>&1; then
  for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$_brew" ]; then eval "$("$_brew" shellenv)"; break; fi
  done
  unset _brew
fi

export CLICOLOR=1
export EDITOR=vim

alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias preview='open -a Preview'
alias ql='qlmanage -p'
alias ll='ls -lah'
alias ..='cd ..'
EOF
)"

BLOCK_SSH="$(cat <<'EOF'
Host *
  ServerAliveInterval 60
  ServerAliveCountMax 5
  AddKeysToAgent yes
EOF
)"

BLOCK_VIM="$(cat <<'EOF'
syntax enable
set mouse=a
set ruler
set showmatch
set tabstop=4
set shiftwidth=4
EOF
)"

BLOCK_GDB="$(cat <<'EOF'
set disassembly-flavor intel
EOF
)"

# ---------------------------------------------------------------------------
# Secciones
# ---------------------------------------------------------------------------
preflight() {
  log "Preflight"
  note "macOS $(sw_vers -productVersion) ($(uname -m))"
  note "shell: ${SHELL:-desconocido}"

  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  if [ "$major" -lt 11 ] 2>/dev/null; then
    warn "probado en macOS 11+; en versiones más viejas algunas claves pueden no existir."
  fi
  if [ "$(uname -m)" != "arm64" ]; then
    warn "no es Apple Silicon: igual funciona, pero los ajustes de '--low-mem' apuntan a un M1."
  fi

  if [ ! -d /opt/homebrew ] && [ ! -d /usr/local/Homebrew ]; then
    note "sin Homebrew detectado (no es obligatorio)."
  fi
}

section_dots() {
  log "Dotfiles (bloques idempotentes entre $MARK_BEGIN y $MARK_END)"
  local profile
  case "${SHELL:-}" in
    */bash) profile="$HOME/.bash_profile" ;;
    *)      profile="$HOME/.zshrc" ;;
  esac

  write_block "$profile" "$BLOCK_SHELL"
  write_block "$HOME/.ssh/config" "$BLOCK_SSH"
  write_block "$HOME/.vimrc" "$BLOCK_VIM"

  if command -v gdb >/dev/null 2>&1; then
    write_block "$HOME/.gdbinit" "$BLOCK_GDB"
  else
    skip "gdb no instalado: omito ~/.gdbinit"
  fi

  if [ "$DRY_RUN" != 1 ]; then
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    chmod 600 "$HOME/.ssh/config" 2>/dev/null || true
  fi
}

section_ux() {
  log "UX (Finder, Dock, capturas, teclado)"

  set_default NSGlobalDomain AppleShowAllExtensions -bool true
  set_default com.apple.finder _FXShowPosixPathInTitle -bool true
  set_default com.apple.desktopservices DSDontWriteNetworkStores -bool true
  set_default com.apple.dock show-recents -bool false

  ensure_dir "$HOME/Pictures/Screenshots"
  set_default com.apple.screencapture location -string "$HOME/Pictures/Screenshots"
  set_default com.apple.screencapture type -string png
  set_default com.apple.screencapture disable-shadow -bool true

  set_default NSGlobalDomain KeyRepeat -int 2
  set_default NSGlobalDomain InitialKeyRepeat -int 15
  set_default NSGlobalDomain ApplePressAndHoldEnabled -bool false
  set_default NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
  set_default NSGlobalDomain PMPrintingExpandedStateForPrint -bool true

  set_default com.apple.TextEdit RichText -bool false
}

section_show_hidden() {
  log "Archivos ocultos (--show-hidden)"
  set_default com.apple.finder AppleShowAllFiles -bool true

  if [ -d "$HOME/Library" ]; then
    local flags
    flags="$(stat -f '%Sf' "$HOME/Library" 2>/dev/null || true)"
    case "$flags" in
      *hidden*)
        if [ "$DRY_RUN" = 1 ]; then
          printf '  %s[dry-run]%s chflags nohidden ~/Library\n' "$C_GREY" "$C_RESET"
          PLANNED=$((PLANNED + 1))
        else
          chflags nohidden "$HOME/Library" && ok "~/Library visible"
        fi
        ;;
      *) skip "~/Library ya visible" ;;
    esac
  fi
}

section_safari() {
  log "Safari: menú Desarrollo (--safari-dev)"
  if pgrep -x Safari >/dev/null 2>&1; then
    warn "Safari está abierto: cerrálo o los cambios se pueden pisar."
  fi
  set_default com.apple.Safari IncludeDevelopMenu -bool true
  set_default com.apple.Safari WebKitDeveloperExtrasEnabledPreferenceKey -bool true
}

section_low_mem() {
  log "8 GB / Apple Silicon: menos gasto en animaciones y servicios (--low-mem)"
  set_default com.apple.dock expose-animation-duration -float 0.1
  set_default com.apple.dock launchanim -bool false
  set_default NSGlobalDomain NSAutomaticWindowAnimationsEnabled -bool false
  set_default NSGlobalDomain NSScrollAnimationEnabled -bool false
  set_default com.apple.universalaccess reduceTransparency -bool true
  set_default com.apple.assistant.support "Assistant Enabled" -bool false
  set_default com.apple.Siri StatusMenuVisible -bool false
  note "reduceTransparency y Siri necesitan cerrar sesión para notarse del todo."
}

section_firewall() {
  log "Firewall (--firewall)"
  has_sudo || return 0
  run_sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
  run_sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
  note "a propósito NO uso --setblockall (rompe AirDrop, compartir archivos y servers locales)."
}

section_spotlight() {
  log "Spotlight (--no-spotlight)"
  has_sudo || return 0
  run_sudo mdutil -a -i off
  warn "Spotlight apagado: para volver atrás, 'sudo mdutil -a -i on'."
}

section_restart() {
  log "Reinicio de procesos para aplicar los cambios"
  if [ "$DRY_RUN" = 1 ]; then
    printf '  %s[dry-run]%s killall Finder Dock SystemUIServer cfprefsd\n' "$C_GREY" "$C_RESET"
    PLANNED=$((PLANNED + 1))
  else
    killall Finder 2>/dev/null || true
    killall Dock 2>/dev/null || true
    killall SystemUIServer 2>/dev/null || true
    killall cfprefsd 2>/dev/null || true
    ok "Finder / Dock / SystemUIServer / cfprefsd reiniciados"
  fi
}

do_remove_blocks() {
  log "Quitando los bloques de tweakmeup-m1"
  local profile
  case "${SHELL:-}" in
    */bash) profile="$HOME/.bash_profile" ;;
    *)      profile="$HOME/.zshrc" ;;
  esac
  remove_block "$profile"
  remove_block "$HOME/.ssh/config"
  remove_block "$HOME/.vimrc"
  remove_block "$HOME/.gdbinit"
}

# ---------------------------------------------------------------------------
# Self-test (usa TWEAKMEUP_ROOT, no toca tu sistema; solo un dominio de prueba)
# ---------------------------------------------------------------------------
self_test() {
  local tmp failures=0
  tmp="$(mktemp -d -t tweakmeup-test)"
  FILE_ROOT="$tmp/"
  DRY_RUN=0

  check() { # check <desc> <0|1>
    if [ "$2" = 0 ]; then
      note "OK   $1"
    else
      warn "FAIL $1"
      failures=$((failures + 1))
    fi
  }

  write_block "zshrc" "linea a" >/dev/null
  grep -q "^linea a$" "$tmp/zshrc" && check "write_block escribe el contenido" 0 || check "write_block escribe el contenido" 1
  [ "$(grep -cF "$MARK_BEGIN" "$tmp/zshrc")" = 1 ] && check "un solo marcador de inicio" 0 || check "un solo marcador de inicio" 1

  printf 'contenido mio\n' > "$tmp/keep"
  write_block "keep" "bloque uno" >/dev/null
  write_block "keep" "bloque uno" >/dev/null
  [ "$(grep -cF "$MARK_BEGIN" "$tmp/keep")" = 1 ] && check "rerun no duplica el bloque" 0 || check "rerun no duplica el bloque" 1
  grep -q "^contenido mio$" "$tmp/keep" && check "conserva el contenido del usuario" 0 || check "conserva el contenido del usuario" 1

  write_block "keep" "bloque dos" >/dev/null
  grep -q "^bloque uno$" "$tmp/keep" && check "reemplaza el bloque viejo" 1 || check "reemplaza el bloque viejo" 0
  grep -q "^bloque dos$" "$tmp/keep" && check "deja el bloque nuevo" 0 || check "deja el bloque nuevo" 1

  remove_block "keep" >/dev/null
  [ "$(grep -cF "$MARK_BEGIN" "$tmp/keep")" = 0 ] && check "remove_block limpia los marcadores" 0 || check "remove_block limpia los marcadores" 1
  grep -q "^contenido mio$" "$tmp/keep" && check "remove_block conserva lo del usuario" 0 || check "remove_block conserva lo del usuario" 1

  # set_default: idempotencia real contra un dominio de prueba
  defaults delete "$SELFTEST_DOMAIN" >/dev/null 2>&1 || true
  defaults write "$SELFTEST_DOMAIN" k -bool true
  CHANGED=0
  set_default "$SELFTEST_DOMAIN" k -bool true >/dev/null
  [ "$CHANGED" = 0 ] && check "set_default no reescribe si ya está" 0 || check "set_default no reescribe si ya está" 1
  set_default "$SELFTEST_DOMAIN" k -bool false >/dev/null
  [ "$CHANGED" = 1 ] && check "set_default escribe cuando cambia" 0 || check "set_default escribe cuando cambia" 1
  defaults delete "$SELFTEST_DOMAIN" >/dev/null 2>&1 || true
  [ -z "$(defaults read "$SELFTEST_DOMAIN" 2>/dev/null || true)" ] && check "limpia el dominio de prueba" 0 || check "limpia el dominio de prueba" 1

  # El bloque de shell y el de SSH tienen que ser válidos en lo que hay acá
  local sshbin validated
  if command -v zsh >/dev/null 2>&1; then
    printf '%s\n' "$BLOCK_SHELL" > "$tmp/rc.zsh"
    zsh -n "$tmp/rc.zsh" 2>/dev/null && check "bloque de shell valido en zsh" 0 || check "bloque de shell valido en zsh" 1
  fi
  printf '%s\n' "$BLOCK_SHELL" > "$tmp/rc.bash"
  /bin/bash -n "$tmp/rc.bash" 2>/dev/null && check "bloque de shell valido en bash 3.2" 0 || check "bloque de shell valido en bash 3.2" 1

  validated=0
  printf '%s\n' "$BLOCK_SSH" > "$tmp/sshcfg"
  for sshbin in /usr/bin/ssh /opt/homebrew/bin/ssh; do
    [ -x "$sshbin" ] || continue
    validated=1
    if "$sshbin" -F "$tmp/sshcfg" -G tweakmeup.invalid >/dev/null 2>&1; then
      check "bloque SSH valido para $sshbin" 0
    else
      check "bloque SSH valido para $sshbin" 1
    fi
  done
  [ "$validated" = 0 ] && note "no hay ssh para validar el bloque (skip)"

  rm -rf "$tmp"
  FILE_ROOT=""
  CHANGED=0

  if [ "$failures" -gt 0 ]; then
    die "$failures prueba(s) fallaron"
  fi
  log "self-test: todas las pruebas pasaron"
}

# ---------------------------------------------------------------------------
# Argumentos / main
# ---------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--dry-run)     DRY_RUN=1 ;;
      --dots-only)      DOTS_ONLY=1 ;;
      --low-mem)        WITH_LOW_MEM=1 ;;
      --firewall)       WITH_FIREWALL=1 ;;
      --no-spotlight)   NO_SPOTLIGHT=1 ;;
      --show-hidden)    SHOW_HIDDEN=1 ;;
      --safari-dev)     SAFARI_DEV=1 ;;
      --no-restart)     NO_RESTART=1 ;;
      --remove-blocks)  REMOVE_BLOCKS=1 ;;
      --self-test)      SELF_TEST=1 ;;
      -h|--help)        usage; exit 0 ;;
      --version)        printf 'tweakmeup-m1 %s\n' "$VERSION"; exit 0 ;;
      *)                die "opción desconocida: $1 (probá --help)" ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  if [ "$SELF_TEST" = 1 ]; then
    self_test
    exit 0
  fi

  if [ "$DRY_RUN" = 1 ]; then
    log "Modo dry-run: no se escribe nada."
  fi

  preflight

  if [ "$REMOVE_BLOCKS" = 1 ]; then
    do_remove_blocks
    log "Listo. Cambios: $CHANGED (planificados: $PLANNED)"
    exit 0
  fi

  if [ "$DOTS_ONLY" = 1 ]; then
    section_dots
    log "Listo (solo dotfiles). Cambios: $CHANGED (planificados: $PLANNED)"
    note "reiniciá el shell (o 'source' tu rc) para tomar los cambios."
    exit 0
  fi

  section_dots
  section_ux
  [ "$SHOW_HIDDEN" = 1 ] && section_show_hidden
  [ "$SAFARI_DEV" = 1 ] && section_safari
  [ "$WITH_LOW_MEM" = 1 ] && section_low_mem
  [ "$WITH_FIREWALL" = 1 ] && section_firewall
  [ "$NO_SPOTLIGHT" = 1 ] && section_spotlight

  if [ "$NO_RESTART" = 1 ]; then
    note "sin reiniciar procesos (--no-restart): cerrá sesión para ver todo."
  else
    section_restart
  fi

  log "Resumen"
  note "cambios aplicados: $CHANGED"
  if [ "$DRY_RUN" = 1 ]; then
    note "planificados (dry-run, nada escrito): $PLANNED"
    note "volvé a correrlo sin --dry-run para aplicar."
  else
    note "volvé a correrlo cuando quieras: es idempotente."
  fi
}

main "$@"
