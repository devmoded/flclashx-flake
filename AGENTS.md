# AGENTS.md — FlClashX flake

Заметки и правила для агентов, которые будут поддерживать этот flake.
Порт с **0.4.2** на **0.5.x** выполнен в ветке `port/0.5.8`; текущая
закреплённая версия — FlClashX **v0.5.8**.

> **Статус:** порт выполнен, пакет собирается и проходит проверки из §7.
> Живой прогон GUI/TUN на NixOS-хосте ещё нужен — см. §8.

---

## 0. TL;DR

FlClashX 0.5.x сменил модель привилегий и сборки:

| Было (0.4.2)                                  | Стало (0.5.x)                                      |
| --------------------------------------------- | -------------------------------------------------- |
| `security.wrappers` + setuid/caps             | root systemd-сервис `flclashx-helper`               |
| `coreWrapperPath`, ядро в `$out/app/...`      | ядро внутри bundle + `manifest.json`               |
| патч `lib/common/system.dart`                 | не нужен, код проверки привилегий переписан         |
| CMake собирает ядро                           | Dart build hooks (`plugins/setup/hook/build.dart`)  |
| только Go-ядро                                | Go-ядро + Rust helper + `librust_api.so`            |
| `flutter_js` (git)                            | `launch_at_startup` (git), `flutter_js` удалён      |

Рецепт-образец той же архитектуры — **`github:YeFaDa/flclash-nix`**
(FlClash 0.9.1). Из него взяты общие приёмы, но имена файлов, каталоги и
часть поведения отличаются — сверяться с upstream, а не копировать слепо.

---

## 1. Жёсткие правила (не нарушать)

1. **Не возвращаться к старой TUN-схеме.** `security.wrappers`,
   `capabilities`, `setuid`, `coreWrapperPath` и
   `substituteInPlace lib/common/system.dart` в 0.5.x не нужны и не сработают.
2. **Ядро `FlClashCore` нельзя strip / patchelf / переупаковывать.**
   Helper встраивает его SHA-256 при сборке и отказывается запускать ядро при
   несовпадении. Нужны `dontStrip = true`, `dontPatchELF = true`.
   SHA должен совпадать в трёх местах: сам бинарник, `manifest.json`, helper.
3. **`librust_api.so` обязателен.** Без него не работают `RustLib.init()`,
   IPC с ядром, хоткеи, JS-скрипты и редактор. Он должен лежать в
   `$out/app/flclashx/lib/`, а wrapper — добавлять этот каталог в
   `LD_LIBRARY_PATH` (см. §4.3).
4. **Не запускать Dart build hooks в сандбоксе Nix.** Они собирают Go/Rust и
   требуют сеть/crates. Отключать через `build_assets: false` и подкладывать
   готовые артефакты в `libclash/linux/` перед сборкой приложения.
5. **Не удалять и не «чинить» `manifest.json`.** Его формат и содержимое
   проверяются helper'ом (`{"coreSha256":"<hex>"}`, `deny_unknown_fields`).
6. **Не патчить `pubspec.lock`.** Если nixpkgs не знает версию pub-пакета —
   использовать `customSourceBuilders`, а не переписывать lock.
   Исключение — `pubspecLock.sdks.dart` в `flake.nix` (см. §4.5): это не файл,
   а attrset, который nixpkgs использует как language version корневого пакета.
7. **Проверять `build_config.yaml` перед каждой сменой версии.** Там версия
   ядра, теги, имена файлов и каталогов. Они читаются в `flake.nix`
   (`readBuildConfig`), не хардкодить без нужды.

---

## 2. Текущее состояние репозитория

- Один файл `flake.nix`: пакет, overlay, NixOS-модуль.
- `flake.lock`:
  - `nixpkgs` → `02c087f3fe673c9e317f206a627cb6b910336dbe` (nixos-unstable);
  - `flclashx-src` → `pluralplay/FlClashX@ee0160c9...` (`v0.5.8`).
- Пакеты: `flclashx` (по умолчанию), `flclashx-core`, `flclashx-helper`,
  `flclashx-rust-api`. У приложения есть
  `passthru = { core; helper; rustApi; }`.
- В закреплённом nixpkgs: `flutter347` = **3.47.4** (Dart 3.13.3),
  `go` = **1.26.9** (`buildGo126Module`), `rustc`/`cargo` = **1.99.0**.
- Платформа — только `x86_64-linux` (upstream собирает только её; при
  необходимости можно расширять).
- `README.md` описывает актуальную helper-схему TUN.
- `LICENSE` — не трогать.

---

## 3. Закреплённая версия upstream

- Тег `v0.5.8`, коммит `ee0160c908d31e0f82af3ed0df40c68aca2e261c`.
- `pubspec.yaml`: `version: 0.5.8+2026111801`,
  `environment.sdk: '>=3.10.0 <4.0.0'`.
- `pubspec.lock`: `sdks.dart = ">=3.13.2 <4.0.0"`, `sdks.flutter = ">=3.47.2"`.
- `build_config.yaml`:

  ```yaml
  tags: with_gvisor
  android_tags: with_gvisor,cmfa
  go_ldflags: "-w -s"
  core_version: v1.19.34
  core_dir: core
  core_name: FlClashCore
  output_dir: libclash
  helper_dir: services/helper
  helper_name: FlClashXHelperService
  ```

- `core/go.mod`: `module core`, `go 1.26.0`, локальный `replace` на
  `./third_party/sing-tun`. Main-пакет — `./cmd/core`, **не** корень `core/`.

Между 0.5.7 и 0.5.8 build-система не менялась; `v0.5.9-pre.1` — prerelease,
не использовать как «стабильную».

---

## 4. Как устроен `flake.nix`

### 4.1 Go-ядро (`flclashx-core`)

- `buildGo126Module`, `modRoot = "core"`, `subPackages = [ "./cmd/core" ]`.
- `CGO_ENABLED=0`, `tags = [ "with_gvisor" ]`,
  `ldflags = [ "-s" "-w" "-X .../constant.Version=<core_version>" ]`.
- `postInstall` переименовывает `core` → `FlClashCore` (имя из
  `build_config.yaml`).
- `dontStrip`/`dontPatchELF` обязательны (см. §1.2).
- Не передавать `go = ...` в `buildGoModule`: это не меняет сборщик vendor-FOD.
  Выбирать именно `buildGo126Module`.

### 4.2 Rust helper (`flclashx-helper`)

- `services/helper`, `rustPlatform.buildRustPackage`, `src` — подкаталог
  upstream-дерева.
- `preBuild` экспортирует `CORE_SHA256` (считается из уже собранного ядра) и
  `CORE_NAME`; `build.rs` встраивает их в бинарник.
- `postInstall` переименовывает `helper` → `FlClashXHelperService`.
- Работает от root, перед запуском ядра сбрасывает привилегии
  (`setresgid`/`setresuid`).
- Unix-сокет `/run/flclashx/helper.sock`, режим `0660`; **chmod, но не chown** —
  группа сокета = primary group процесса helper.
- Авторизация по peer credentials: UID клиента должен совпадать с owner UID.
- Требует `FLCLASH_HELPER_OWNER_UID` / `FLCLASH_HELPER_OWNER_GID` (не 0).
- Ядро ищется рядом с бинарником helper (`current_exe().parent()/CORE_NAME`),
  поэтому в bundle они лежат в одном каталоге.

### 4.3 Rust API (`flclashx-rust-api`)

- `plugins/rust_api/rust`, cdylib `librust_api.so`.
- Собирается отдельным `buildRustPackage`; `installPhase` использует `find`,
  потому что cargo кладёт артефакт в `target/<triple>/release/`.
- Приложению ставится в `$out/app/flclashx/lib/librust_api.so`.
- `flutter_rust_bridge` на Linux делает `DynamicLibrary.open('librust_api.so')`.
  У `libflutter_linux_gtk.so` в RUNPATH есть `$ORIGIN`, но wrapper всё равно
  добавляет bundle `lib/` в `LD_LIBRARY_PATH` — не убирать без проверки.

### 4.4 Dart hooks

`pubspec.yaml` upstream:

```yaml
hooks:
  user_defines:
    setup:
      build_assets: true
    rust_api:
      build_assets: true
```

`postPatch` заменяет обе строки `build_assets: true` → `false`. После этого
Flutter не пытается собирать Go/Rust сам, а `linux/CMakeLists.txt` ставит в
bundle `libclash/linux/{FlClashCore,FlClashXHelperService,manifest.json}`,
которые `preBuild` кладёт туда вручную.

### 4.5 Языковая версия Dart

nixpkgs берёт `sdks.dart` из `pubspec.lock` как language version **корневого**
пакета, а pub пишет туда минимум зависимостей (`>=3.13.2`). В 0.5.8 есть
`final`-модификаторы параметров, которые Dart 3.13 отвергает, а язык 3.10 —
принимает. Поэтому в `mkApp`:

```nix
lock = lib.importJSON (pkgs.runCommand "flclashx-pubspec-lock" { nativeBuildInputs = [ pkgs.yq ]; } ''
  yq . ${flclashx-src}/pubspec.lock > "$out"
'');
pubspecLock = lock // { sdks = lock.sdks // { dart = ">=3.10.0 <4.0.0"; }; };
```

Это IFD (yq на eval), но он уже используется nixpkgs-сборщиком через
`autoPubspecLock`.

### 4.6 Приложение (`flclashx`)

- `flutter347.buildFlutterApplication` + `pubspecLock`, `gitHashes`.
- `customSourceBuilders.sqlcipher_flutter_libs = { src, ... }: src` — пакет
  `0.7.0+eol` стал пустой заглушкой без `linux/CMakeLists.txt`, и штатный
  builder падает на `postPatch`.
- `flutterBuildFlags`: `APP_ENV=stable`, `APP_VERSION=<version>`,
  `CORE_VERSION=<core_version>` (как в upstream `setup.dart`).
- `buildInputs`: `gtk3`, `glib`, `gdk-pixbuf`, `cairo`, `pango`, `atk`,
  `harfbuzz`, `libepoxy`, `libayatana-appindicator` (tray), `libx11`
  (`pkg_check_modules(X11 REQUIRED)`). `keybinder3` больше не нужен — хоткеи
  ушли в Rust.
- `postInstall` удаляет из `$out/bin` `FlClashCore`, `FlClashXHelperService` и
  `manifest.json` (сборщик линкует туда все файлы bundle).
- Desktop entry: `name`/`startupWMClass` = `com.follow.clashx`
  (`APPLICATION_ID` из `linux/CMakeLists.txt`), `exec` = `FlClashX`.
- `waylandBackend` — параметр `override`, ставит `GDK_BACKEND=wayland`.

---

## 5. NixOS-модуль

Опции `programs.flclashx`: `enable`, `package`, `wayland.enable`,
`tunMode.{enable,user,exemptFromReversePathFilter,interfaceName}`.

- `tunMode.user` по умолчанию — единственный `isNormalUser`, иначе `null`;
  если `tunMode.enable = true` и owner не определён — assertion с просьбой
  задать пользователя явно.
- `ownerGroup` = `users.users.<owner>.group` (fallback `users`).
- Юнит `flclashx-helper` создаётся только при `tunMode.enable && owner != null`:
  - `ExecStart` — shell-скрипт, который в **рантайме** делает
    `id -u`/`id -g` для owner, экспортирует `FLCLASH_HELPER_OWNER_UID/GID` и
    делает `exec ${appPackage}/app/flclashx/FlClashXHelperService`;
  - `appPackage` — `cfg.package.override { waylandBackend = cfg.wayland.enable; }`,
    посчитанный **один раз** в `let`: приложение ищет helper по пути
    `dirname(resolvedExecutable)/FlClashXHelperService` и отвергает helper из
    другого store-пути (`helper executable path mismatch`), после чего
    запускает ядро без привилегий. Поэтому `systemPackages` и юнит обязаны
    брать один и тот же пакет;
  - `Group = ownerGroup` (иначе helper создаст сокет с группой root и
    приложение не подключится);
  - `RuntimeDirectory = flclashx`, `RuntimeDirectoryMode = 0755`;
  - `ExecStartPost` ждёт сокет и делает `chgrp ownerGroup` как страховку;
  - `Restart = on-failure`, `RestartSec = 5`, лимиты как у upstream.
- NixOS создаёт `/etc/systemd/system/flclashx-helper.service` — именно этот
  путь проверяет приложение (`helperUnitPathFor`).
- rpfilter: при `exemptFromReversePathFilter = true` и включённом фаерволе
  TUN-интерфейс исключается из проверки обратного пути (iptables:
  `nixos-fw-rpfilter`, nftables: `extraReversePathFilterRules`). Без этого DNS
  под TUN работает очень медленно.
- `wayland.enable` прокидывается в пакет через `override { waylandBackend = ...; }`.

---

## 6. Хэши

В `flake.nix` (все посчитаны под v0.5.8 / закреплённый nixpkgs):

| Что                              | Значение                                              |
| -------------------------------- | ----------------------------------------------------- |
| `vendorHash` (core/go.sum)       | `sha256-/lx1/OfWcHS0GFXgvqx/jUxOoNmUBukyRWDBFxQNoMw=` |
| `helperCargoHash`                | `sha256-M7m+rs96S4CkQK/mnJ+5IcHXQKMl3Yp2bovdpwc+Nn4=` |
| `rustApiCargoHash`               | `sha256-5ie8iNeumnThUHet6BULxlqEygVfbE+YoZ9SQxk9Lrc=` |
| `gitHashes.launch_at_startup`    | `sha256-vr679QsLuIYyW9gaAHA4Uya4f6spWHViijDJSEnfrPw=` |

Порядок обновления: `nix flake update flclashx-src` → заменить нужный хэш на
`lib.fakeHash` → собрать → подставить `got:`.

---

## 7. Сборка и проверки

```bash
nix build .#flclashx-core
nix build .#flclashx-helper
nix build .#flclashx-rust-api
nix build .#flclashx
nix flake check          # eval модуля + сборка всех outputs
```

Проверено на 0.5.8:

- `manifest.json` == `sha256sum $out/app/flclashx/FlClashCore` == SHA,
  встроенный в helper (`grep -a` по бинарнику);
- `librust_api.so` есть в `$out/app/flclashx/lib/`, wrapper содержит
  `LD_LIBRARY_PATH` на этот каталог;
- `ldd` для ядра, helper, `librust_api.so` и лаунчера — все зависимости
  найдены;
- запуск без дисплея доходит до GTK (`cannot open display`), то есть бинарник
  стартует и грузит библиотеки;
- в `$out/bin` только `FlClashX`;
- NixOS-модуль: eval с одним/двумя пользователями, автоопределение owner,
  assertion при неоднозначности, `Group`, `ExecStart`/`ExecStartPost`,
  iptables- и nftables-правила.

---

## 8. Риски и что проверить на живой системе

1. **TUN end-to-end** — включение TUN, интерфейс `FlClashX`, DNS под TUN,
   `systemctl status flclashx-helper`, права/группа `/run/flclashx/helper.sock`.
2. **AppImage/не-systemd** — `hasHelperService` в 0.5.x истинно для любого
   Linux с systemd; без юнита приложение уйдёт в `pkexec` и провалится.
   Модуль создаёт юнит только при `tunMode.enable`, так что TUN без модуля
   не заработает.
3. **Автозапуск** — `launch_at_startup` пишет путь
   `Platform.resolvedExecutable`, а это внутренний бинарник
   `$out/app/flclashx/FlClashX`, не wrapper из `$out/bin`. Библиотеки он
   найдёт (у движка RUNPATH `$ORIGIN`), но переменные окружения от
   `wrapGAppsHook` (XDG_DATA_DIRS, GIO_EXTRA_MODULES, GDK_PIXBUF_MODULE_FILE)
   потеряются — возможны проблемы с GTK-схемами/иконками. Проверить и, если
   критично, обсудить патч `lib/common/launch.dart` или отдельный autostart.
4. **Права сокета/группы** — проверить на системе с несколькими
   пользователями; при нестандартной primary group задать
   `tunMode.user` явно.
5. **rpfilter** — проверить оба backend'а фаервола; при проблемах с DNS
   сравнить с `networking.firewall.trustedInterfaces`.
6. **Strip/манифест** — любой strip/patchelf ядра ломает helper; проверять
   финальный store-путь после изменений в сборке.
7. **Rust-версия** — upstream пинит канал в `rust-toolchain.toml`; в Nix
   используется rustc из nixpkgs (1.99.0). При обновлении upstream проверить
   `Cargo.lock` и API.

---

## 9. Полезные ссылки

- Upstream: <https://github.com/pluralplay/FlClashX>
- Рецепт-образец: <https://github.com/YeFaDa/flclash-nix>
  - `pkgs/flclash/package.nix`, `modules/flclash.nix`, `pkgs/flclash/update.sh`
- FlClash (родительский проект): <https://github.com/chen08209/FlClash>
- `flutter_rust_bridge`: <https://github.com/fzyzcjy/flutter_rust_bridge>
- AUR-прецедент: PKGBUILD'ы в `.github/aur` upstream.
- Рабочие заметки (вне репозитория): `~/.opencode/plan/flclashx-0.5-port.md`.

---

## 10. Стиль работы

- Язык README/комментариев — русский; код и идентификаторы — английский.
- Правки — минимальные и по теме; не переформатировать `flake.nix` целиком.
- Каждое изменение хэшей сопровождать комментарием, что именно изменилось.
- Крупные изменения — отдельными коммитами («core/helper/rust_api», «app»,
  «module», «docs»).
