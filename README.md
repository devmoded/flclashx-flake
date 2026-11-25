# flclashx-flake

Неофициальный Nix flake для [FlClashX](https://github.com/pluralplay/FlClashX)
(форк FlClash): пакет, overlay и модуль NixOS с поддержкой TUN. Не связан с
авторами FlClashX. Текущая версия — **0.5.8**.

> [!NOTE]
> Flake для FlClashX 0.4.x написан с помощью Claude Sonnet 5.5 High.
> Порт на 0.5.8 выполнен с помощью DeepSeek v4.1 Flash.

## Требования

- NixOS с systemd и включёнными flakes (TUN-режим опирается на
  systemd-сервис; на системах без systemd он не заработает).
- Flutter-тулчейн из nixpkgs: используется `flutter347` (Flutter 3.47.x).
  Пока flake пинится на `nixos-unstable`; можно подключить свой `nixpkgs`
  через `inputs.nixpkgs.follows`, если в нём есть Flutter >= 3.47.
- Только `x86_64-linux` (upstream собирает ядро и helper только под неё).

## Подключение

В flake вашей системы:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flclashx = {
      url = "github:devmoded/flclashx-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, flclashx, ... }: {
    nixosConfigurations.ХОСТ = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix
        flclashx.nixosModules.default
        {
          programs.flclashx = {
            enable = true;
            tunMode.enable = true;  # root-сервис flclashx-helper
            wayland.enable = true;  # только для Wayland-сессий
          };
        }
      ];
    };
  };
}
```

Быстрый запуск без установки: `nix run github:devmoded/flclashx-flake`.
Так TUN не заработает: для него нужен NixOS-модуль (root-сервис helper'а).

Если в системе несколько обычных пользователей, укажите владельца TUN-сессии
явно:

```nix
programs.flclashx.tunMode.user = "alice";
```

## Опции `programs.flclashx`

| Опция                                 | По умолчанию   | Описание                                                          |
| ------------------------------------- | -------------- | ----------------------------------------------------------------- |
| `enable`                              | `false`        | Установить FlClashX                                               |
| `package`                             | пакет из flake | Другой пакет (должен принимать `waylandBackend`)                  |
| `wayland.enable`                      | `false`        | Принудительно `GDK_BACKEND=wayland`                               |
| `tunMode.enable`                      | `false`        | Включить root-сервис `flclashx-helper` для TUN                    |
| `tunMode.user`                        | авто           | Владелец TUN-сессии (единственный нормальный пользователь)        |
| `tunMode.exemptFromReversePathFilter` | `true`         | Исключить TUN-интерфейс из проверки обратного пути фаервола       |
| `tunMode.interfaceName`               | `FlClashX`     | Имя TUN-устройства для правила rpfilter (как в настройках приложения) |

## Как работает TUN в 0.5.x

Начиная с 0.5.x привилегии не выдаются самому приложению: ядро для TUN
запускает отдельный root-сервис.

- Модуль создаёт systemd-юнит `flclashx-helper`
  (`/etc/systemd/system/flclashx-helper.service`) и добавляет
  `/run/flclashx` (`RuntimeDirectory`).
- Helper слушает unix-сокет `/run/flclashx/helper.sock` с правами `0660`.
  Группа сокета — primary group владельца, поэтому юнит запускается с
  `Group = <группа пользователя>`.
- Подключиться к helper'у может только процесс с UID владельца (проверка по
  peer credentials через `SO_PEERCRED`). Остальные пользователи системы
  доступа к ядру не получают.
- Helper сам сбрасывает привилегии перед запуском ядра и проверяет SHA-256
  ядра по `manifest.json`, встроенному в пакет. Поэтому ядро нельзя
  strip/patchelf — этот flake собирает его с `dontStrip`/`dontPatchELF`.
- Приложение и helper устанавливаются из одного store-пути. Приложение ищет
  helper рядом со своим бинарником и отвергает helper из другого пути, после
  чего запускает ядро без привилегий. Поэтому при замене `package` нужно
  брать пакет, в котором helper лежит рядом с приложением.
- В фаервол добавляется правило, исключающее TUN-интерфейс из проверки
  обратного пути (iptables и nftables). Без него DNS под TUN работает очень
  медленно. Отключается через
  `tunMode.exemptFromReversePathFilter = false`.

Если `tunMode.enable` выключен, юнита нет. Приложение в такой конфигурации
всё равно считает (на Linux с systemd), что helper должен существовать, и при
включении TUN попытается поставить его через `pkexec` — на NixOS это не
сработает. Включайте `tunMode.enable`.

Если TUN поднимается, но трафик идёт напрямую (IP не меняется), это не
проблема flake'а — см. [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Обновление

В этом репозитории версия FlClashX зафиксирована в `flake.lock`, а хэши в
`flake.nix` посчитаны под неё. У себя достаточно:

```bash
nix flake update flclashx
sudo nixos-rebuild switch --flake .#ХОСТ
```

## В случае несовпадения хэшей

Если после обновления сборка падает с `hash mismatch`:

1. Замените нужный хэш (`vendorHash`, `helperCargoHash`, `rustApiCargoHash`
   или значение в `gitHashes`) на `lib.fakeHash`.
2. Запустите сборку снова.
3. Скопируйте значение из строки `got:` и подставьте обратно.

Хэши привязаны к `core/go.sum`, `services/helper/Cargo.lock`,
`plugins/rust_api/rust/Cargo.lock` и git-зависимости `launch_at_startup`.

## Известные ограничения

- Автозапуск (галочка в настройках) использует путь к внутреннему бинарнику
  пакета, а не к wrapper'у из `bin/`. Библиотеки при этом находятся, но
  переменные окружения GTK из wrapper'а теряются — возможны проблемы с
  GTK-схемами и иконками. Проверяйте после включения.
- TUN работает только вместе с `programs.flclashx.tunMode.enable`.
- Правило rpfilter ставится только для backend'ов `iptables` и `nftables`.
  При `services.firewalld.enable = true` (`networking.firewall.backend =
  "firewalld"`) правило не добавляется, и DNS под TUN может работать
  медленно.
- Платформа — только `x86_64-linux`.

## Благодарности

- [FlClashX](https://github.com/pluralplay/FlClashX) — upstream-проект
- [FlClash](https://github.com/chen08209/FlClash) — родительский проект
- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) — Go-ядро
- [MetaCubeX/sing-tun](https://github.com/MetaCubeX/sing-tun) — TUN-стек
  (в FlClashX используется его форк)
- [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge) —
  связка Dart и Rust (`librust_api.so`)
- [launch_at_startup](https://github.com/chen08209/launch_at_startup) — форк,
  используемый FlClashX для автозапуска
- [`flake.nix` из FlClashX PR #118 от endotrizine](https://github.com/pluralplay/FlClashX/pull/118)
- [`package.nix` клиента Throne из nixpkgs](https://github.com/NixOS/nixpkgs/blob/nixos-26.05/pkgs/by-name/th/throne/package.nix)
- [`throne.nix` из nixpkgs](https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/programs/throne.nix)
- [`YeFaDa/flclash-nix`](https://github.com/YeFaDa/flclash-nix) — рецепт
  упаковки FlClash с Go-ядром, Rust helper'ом и `librust_api.so`
