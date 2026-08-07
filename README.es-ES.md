

<div align="center">

<img src="docs/icon.png" width="128" alt="TheGit">

# TheGit

**Un cliente de Git nativo para macOS que no incluye un navegador.**

14 MB. Un proceso. ~95 MB de RAM con un repositorio abierto.<br>
Sin cuentas, sin telemetría, sin muros de inicio de sesión.

[![Release](https://img.shields.io/github/v/release/zjywill/TheGit?color=blue)](https://github.com/zjywill/TheGit/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/zjywill/TheGit/total?color=blue)](https://github.com/zjywill/TheGit/releases)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/SwiftUI-native-orange?logo=swift&logoColor=white)](Sources/TheGit)
[![License](https://img.shields.io/github/license/zjywill/TheGit?color=green)](LICENSE)

</div>

<img src="docs/screenshot.png" alt="TheGit mostrando su propio repositorio: barra lateral de ramas, gráfico de commits, panel de staging">

## Cómo obtenerlo

```bash
brew install zjywill/tap/thegit
```

O [**descarga el DMG**](https://github.com/zjywill/TheGit/releases/latest) —
universal, 4.9 MB, no requiere cadena de herramientas.
[Los detalles de instalación, incluida la advertencia de Gatekeeper al primer lanzamiento](#install), se encuentran más abajo.

---

## Por qué es 45× más pequeño

Los clientes de escritorio principales incluyen un navegador para dibujar un gráfico de commits.
GitKraken es una aplicación Electron: Chromium, Node y una flota de procesos auxiliares,
todos residentes antes de haber leído un solo commit.

TheGit es un único proceso nativo de SwiftUI que ejecuta `git` externamente. Esa es
toda la arquitectura, y esa es toda la historia del rendimiento.

| | TheGit | GitKraken |
|---|---:|---:|
| Paquete de aplicación | **14 MB** (universal) | 621 MB |
| DMG de la versión | **4.9 MB** | — |
| Procesos en reposo | **1** | 7+ |
| Memoria residente, repositorio abierto | **~95 MB** | ~1.6 GB |
| Chromium incluido | ninguno | 261 MB |

Esto se refleja en el uso:

- **Lanzamiento instantáneo** — sin arranque de Chromium, sin pantalla de carga.
- **Nada indexa en segundo plano** — un observador FSEvents decide cuándo cambia realmente
  el estado, en lugar de un temporizador consultando cada repositorio que hayas abierto.
- **El gráfico se maqueta en Swift, no en un DOM** — un solo pase sobre la lista de
  commits ([`Core/GraphLayout.swift`](Sources/TheGit/Core/GraphLayout.swift)),
  dibujado con formas de SwiftUI.
- **El desplazamiento y el zoom son nativos de AppKit** — cinco niveles de zoom relayout de forma
  nativa en lugar de escalar una vista web.

Utiliza el binario de `git` que ya tienes. Sin motor Git embebido, sin daemon,
sin servicio intermedio: tu asistente de credenciales, claves SSH y hooks funcionan
exactamente igual que en la terminal.

Esta elección es deliberada: TheGit es solo para macOS y hace exactamente lo que hace `git`.
No incorporará un kit de IU multiplataforma ni un gestor de incidencias integrado.

> Medido en macOS 26.5 / Apple M4 Pro con un repositorio de tamaño medio abierto;
> las cifras de GitKraken están sumadas en todos sus procesos. Mide los tuyos
> con Monitor de actividad.

---

## Qué obtienes

🌳 **Un gráfico de commits legible.** Las líneas de rama tienen su propio color en lugar
de heredar el de un carril, por lo que una rama mantiene un solo color durante toda su vida incluso
cuando se reutilizan los carriles. El trabajo sin commit aparece como un nodo WIP (trabajo en progreso
progreso) discontinuo en la parte superior, conectado a HEAD.

🪟 **Tres paneles, una pantalla.** Ramas a la izquierda, gráfico en el centro, staging a la derecha.
Haz clic en un archivo y el diff se superpone al gráfico en lugar de mover los paneles; <kbd>Esc</kbd>
para volver.

📚 **Todo en la barra lateral.** Ramas locales y remotas en un árbol expandible con la rama actual fijada
en la parte superior, más Tags, Stashes, Worktrees, Submódulos, Git LFS, y — si `gh` o `glab` están
conectados — tus Pull/Merge Requests abiertos.

✅ **Staging que se adapta a tu flujo de trabajo.** Añade o quita archivos al staging individualmente o todos a
la vez, descarta, ignora (a nivel de repositorio o `.git/info/exclude`), guarda solo lo staged o solo lo
unstaged, crea un parche a partir de los cambios de un archivo, corrige (amend).

🔀 **Operaciones con ramas sin necesidad de consultar la página de manual.** Fusionar (merge), rebase,
cherry-pick, revert, reset, fast-forward, tag, push/pull/fetch, configurar upstream, crear un worktree —
desde los menús contextuales. Cuando un merge o rebase se detiene por un conflicto, tienes opciones de
Continuar y Abortar, más "usar los nuestros / usar los ajenos" por archivo.

🧹 **Limpieza.** Encuentra ramas cuyo PR fue fusionado, ramas squash-merged en la rama por defecto,
ramas cuyo upstream ha desaparecido y worktrees obsoletos — cuenta los commits que se perderían y no
elimina nada hasta que haces clic.

🤖 **Mensajes de commit con IA** *(opcional, desactivado por defecto)*. Apúntalo a cualquier
proveedor compatible con OpenAI o Anthropic y **Generar** convierte tu diff staged en un mensaje de
commit — Conventional Commits o un resumen sencillo, en inglés, chino o lo que ya use el repositorio.
La clave de API se guarda en el llavero de inicio de sesión, nunca en UserDefaults.

👀 **Detecta cambios realizados en otro lugar.** Haz un commit, checkout o edición desde una terminal y
la vista se actualiza automáticamente.

🗂️ **Múltiples repositorios en pestañas**, y cinco niveles de zoom de la interfaz
(<kbd>⌘=</kbd> / <kbd>⌘-</kbd> / <kbd>⌘0</kbd>).

---

## Privacidad

TheGit se comunica exactamente con dos elementos por defecto: el binario de `git` y tu sistema de
archivos. Tres funciones pueden acceder a la red, y tú controlas las tres:

| Función | Accede a | Por defecto |
|---|---|---|
| Avatares del autor | Gravatar, GitHub | **Desactivado** — Menú Ver |
| Mensajes de commit con IA | el proveedor que configuraste | **Desactivado** — Configuración |
| Comprobación de actualizaciones | `api.github.com`, una vez por lanzamiento | Activado — una solicitud, sin identificadores |

La lista de pull requests utiliza la CLI `gh` / `glab` con la que ya te autenticaste;
TheGit nunca gestiona esos tokens directamente.

---

## Instalación

### Homebrew (recomendado)

```bash
brew install zjywill/tap/thegit
```

La fórmula compila desde el código fuente en tu máquina, lo cual es deliberado: una compilación
que generas tú mismo nunca se cuarentena, por lo que no hace falta eludir Gatekeeper. Una primera
compilación tarda un par de minutos y necesita una cadena de herramientas de Xcode 15+.

Homebrew no puede escribir en `/Applications`, así que copia el paquete tú mismo:

```bash
cp -R "$(brew --prefix thegit)/TheGit.app" /Applications/
```

Una **copia**, no un enlace: Spotlight no indexa ni el prefijo de Homebrew ni el destino de un
enlace, y la aplicación nunca aparecería en la búsqueda.

### DMG

Cada versión incluye un `.dmg` universal en la
[página de Releases](https://github.com/zjywill/TheGit/releases/latest) — sin cadena de herramientas,
sin Homebrew.

TheGit aún no está firmado con un ID de desarrollador de Apple, por lo que macOS bloquea el primer
lanzamiento con «TheGit no se puede abrir». Eso es Gatekeeper rechazando una descarga no notariada,
no un problema de la aplicación, y sucede solo una vez:

1. Abre el DMG y arrastra TheGit a Aplicaciones.
2. Inténtalo abrir; macOS se niega.
3. **Ajustes del sistema → Privacidad y seguridad**, desplázate hacia abajo y haz clic en **Abrir de todos modos**.

O salta el diálogo por completo:

```bash
xattr -dr com.apple.quarantine /Applications/TheGit.app
```

Si ese intercambio no te convence, usa Homebrew: compilar desde el código fuente no lo activa.

### Actualización

TheGit te avisa cuando existe una nueva versión: pregunta a GitHub en el lanzamiento (como máximo
cada seis horas) y muestra un banner de una línea si hay una versión más reciente. Nunca descarga ni
instala nada por sí mismo: el banner enlaza a la página de la versión, y al cerrarlo se silencia esa
versión para siempre.
**Buscar actualizaciones…** en el menú de TheGit lo solicita bajo demanda.

```bash
brew update && brew upgrade thegit
rm -rf /Applications/TheGit.app && cp -R "$(brew --prefix thegit)/TheGit.app" /Applications/
```

Cierra TheGit primero: una aplicación en ejecución mantiene su paquete antiguo. `brew update` debe
indicar «Updated 1 tap»; «Already up-to-date» significa que el tap no se ha actualizado.

<details>
<summary><b>Deja que un agente de IA lo instale por ti</b></summary>

¿Usando Claude Code, Codex o cualquier agente con terminal? Pega esto:

```text
Instala TheGit (https://github.com/zjywill/TheGit), un cliente de Git nativo para macOS, en este Mac via Homebrew:

1. brew install zjywill/tap/thegit
   — compila desde el código fuente, necesita una cadena de herramientas de Xcode 15+; si Homebrew indica que el tap no es de confianza, ejecuta: brew trust --formula zjywill/tap/thegit
2. Copia la aplicación donde Finder y Spotlight puedan verla (un enlace NO es suficiente: Spotlight no lo indexará):
   rm -rf /Applications/TheGit.app && cp -R "$(brew --prefix thegit)/TheGit.app" /Applications/
3. Verifica: brew list --versions thegit, luego abre /Applications/TheGit.app

Si ya está instalado, actualízalo en lugar de instalarlo: cierra TheGit, ejecuta
brew update && brew upgrade thegit y repite el paso 2.
```

</details>

<details>
<summary><b>Confianza en tap de Homebrew, versiones, desinstalación</b></summary>

Homebrew 6 te pide que confíes en los taps de terceros. Instalarlo por su nombre completo registra
esa confianza; si un comando posterior indica que el tap se está ignorando:

```bash
brew trust --formula zjywill/tap/thegit
```

Ver qué versión tienes:

```bash
brew list --versions thegit
```

Desinstalar:

```bash
brew uninstall thegit && brew untap zjywill/tap
```

Esto no toca la copia en `/Applications` — elimínala con `rm -rf /Applications/TheGit.app`. Tus
preferencias (el dominio `defaults` `com.zjywill.TheGit`) y la clave de API en el llavero de inicio
de sesión sobreviven tanto a una actualización como a una desinstalación; elimínalas manualmente
para empezar de cero.

</details>

---

## Requisitos

- macOS 14 (Sonoma) o posterior
- `git` en tu `PATH`
- Cadena de herramientas de Xcode 15+ / Swift 5.9 **para compilar** (no necesaria para el DMG)
- Opcional: `git-lfs`, y `gh` o `glab` para pull requests

<details>
<summary><b>Compílalo tú mismo</b></summary>

```bash
scripts/bundle.sh     # universal dist/TheGit.app + dist/TheGit-<version>.dmg
swift run             # run from source
swift test            # tests
```

Parámetros útiles: `UNIVERSAL=0` compila solo para este Mac, `DMG=0` ensambla la `.app` y se detiene,
`DEST=…` elige el directorio de salida. El paquete está firmado ad-hoc: suficiente para ejecutarlo en
tu propio Mac y en cualquier Mac al que lo copies manualmente, pero no suficiente para distribución
en red, donde Gatekeeper exige un Developer ID y la notarización.

**Estructura del proyecto**

```
Sources/TheGit/
  Core/        git invocation, parsers, graph layout, LFS, forge CLIs, AI
  State/       AppState (open repos) and RepoState (one repository)
  UI/          sidebar, graph, diffs, commit panel, settings
Tests/         parser, graph, cleanup and repo integration tests
scripts/       bundle.sh (app + DMG), release.sh (tag + release + tap),
               make-icon.py, sync-providers.py
```

El catálogo de proveedores de IA en `Sources/TheGit/Resources/providers.json` se genera y confirmase confirma;
`scripts/sync-providers.py` lo regenera y solo se ejecuta para actualizar la lista.

</details>

---

## Licencia

[MIT](LICENSE) © 2026 Junyi Zhang
