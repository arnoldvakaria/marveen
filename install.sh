#!/bin/bash
# Marveen - OS-detect wrapper
# Detects the operating system and launches the appropriate installer.

# ── Language selection ────────────────────────────────────────────────────────
if [[ -z "${MARVEEN_LANG:-}" ]]; then
  echo ""
  echo "  🌍  1. Magyar (HU)    2. English (EN)"
  read -rp "  Language / Nyelv [1/2, default: 1]: " _LANG_CHOICE
  case "${_LANG_CHOICE:-1}" in
    2|en|EN) MARVEEN_LANG=en ;;
    *) MARVEEN_LANG=hu ;;
  esac
fi
export MARVEEN_LANG
# Save language choice for update.sh and other scripts
echo "$MARVEEN_LANG" > "$(dirname "$0")/.lang"
# ─────────────────────────────────────────────────────────────────────────────

# ── Branch selection (if running outside the repo) ────────────────────────────
# Ha a telepito a repon kivulrol fut (nincs package.json), interaktivan bekerjuk
# melyik branch-rol klonozzuk a repot. A WSL wrapper (install-windows.ps1) env-ben
# atadja, ilyenkor nem kerdezunk. A publikus telepito (curl|bash, nem-interaktiv)
# az eredeti defaultot kapja: Szotasz/marveen + main.
if [[ ! -f "$(dirname "$0")/package.json" ]] && [[ -z "${MARVEEN_REPO:-}${MARVEEN_BRANCH:-}" ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
  echo ""
  if [[ "${MARVEEN_LANG:-hu}" == "en" ]]; then
    echo "  📦  Which branch to install from?"
    echo "      (empty = develop branch from your fork)"
    read -rp "  Branch name [develop]: " _BRANCH_INPUT
    _BRANCH_INPUT="${_BRANCH_INPUT:-develop}"
    export MARVEEN_REPO="https://github.com/arnoldvakaria/marveen.git"
    export MARVEEN_BRANCH="$_BRANCH_INPUT"
    echo "  ✓ Installing from: $MARVEEN_REPO ($MARVEEN_BRANCH)"
  else
    echo "  📦  Melyik branch-ről telepítsek?"
    echo "      (üres = develop branch a saját forkból)"
    read -rp "  Branch név [develop]: " _BRANCH_INPUT
    _BRANCH_INPUT="${_BRANCH_INPUT:-develop}"
    export MARVEEN_REPO="https://github.com/arnoldvakaria/marveen.git"
    export MARVEEN_BRANCH="$_BRANCH_INPUT"
    echo "  ✓ Telepítés innen: $MARVEEN_REPO ($MARVEEN_BRANCH)"
  fi
fi
# ─────────────────────────────────────────────────────────────────────────────

case "$(uname -s)" in
  Darwin)
    exec "$(dirname "$0")/install-macos.sh" "$@"
    ;;
  Linux)
    exec "$(dirname "$0")/install-linux.sh" "$@"
    ;;
  *)
    if [[ "${MARVEEN_LANG:-hu}" == "en" ]]; then
      echo "Unsupported operating system: $(uname -s)"
      echo "Supported: macOS (Darwin), Linux (Ubuntu/Debian + Fedora/Nobara/RHEL)"
    else
      echo "Nem támogatott operációs rendszer: $(uname -s)"
      echo "Támogatott: macOS (Darwin), Linux (Ubuntu/Debian + Fedora/Nobara/RHEL)"
    fi
    exit 1
    ;;
esac
