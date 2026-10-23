# flclashx-flake

Неофициальный Nix flake для [FlClashX](https://github.com/pluralplay/FlClashX):
пакет, overlay и модуль NixOS с поддержкой TUN. Не связан с авторами FlClashX.

> [!NOTE]
> Этот flake был написан с помощью Claude Sonnet 5.5 High.

## Требования

- NixOS 26.05 или новее (нужен Flutter >= 3.38), включённые flakes
- Только `x86_64-linux` (в зависимости `flutter_js` лежит готовая x86_64-библиотека)

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
            tunMode.enable = true;  # нужен для TUN
            wayland.enable = true;  # только для Wayland-сессий
          };
        }
      ];
    };
  };
}
```

Быстрый запуск без установки: `nix run github:devmoded/flclashx-flake`.
Так TUN не заработает: для него нужен модуль.

## Опции `programs.flclashx`

| Опция                                 | По умолчанию   | Описание                                                    |
| ------------------------------------- | -------------- | ----------------------------------------------------------- |
| `enable`                              | `false`        | Установить FlClashX                                         |
| `package`                             | пакет из flake | Использовать другой пакет                                   |
| `wayland.enable`                      | `false`        | Принудительно `GDK_BACKEND=wayland`                         |
| `tunMode.enable`                      | `false`        | Запускать ядро через security wrapper с нужными правами     |
| `tunMode.setuid`                      | `false`        | setuid-root вместо capabilities (менее безопасно)           |
| `tunMode.exemptFromReversePathFilter` | `true`         | Исключить TUN-интерфейс из проверки обратного пути фаервола |
| `tunMode.interfaceName`               | `FlClashX`     | Имя TUN-интерфейса                                          |

## Что именно делает `tunMode`

- Ядро запускается через `security.wrappers` (capabilities), поэтому приложение
  не просит пароль `sudo`, что на NixOS всё равно не работает.
- При сборке в `lib/common/system.dart` заменяется одна строка проверки
  привилегий ядра.
- В фаервол добавляется правило, исключающее TUN-интерфейс из проверки
  обратного пути (iptables и nftables). Без него DNS под TUN работает очень
  медленно. Отключается через `tunMode.exemptFromReversePathFilter = false`.

## Обновление

В этом репозитории версия FlClashX зафиксирована в `flake.lock`, а хэши в
`flake.nix` посчитаны под неё. У себя достаточно:

```bash
nix flake update flclashx
sudo nixos-rebuild switch --flake .#ХОСТ
```

## В случае несовпадения хэшей

Если после обновления сборка падает с `hash mismatch`:

1. Замените нужный хэш (`vendorHash` или значение в `gitHashes`) на `lib.fakeHash`.
2. Запустите сборку снова.
3. Скопируйте значение из строки `got:` и подставьте обратно.

## Благодарности

- [`flake.nix` из FlClashX PR #118 от endotrizine](https://github.com/pluralplay/FlClashX/pull/118)
- [`package.nix` клиента Throne из nixpkgs](https://github.com/NixOS/nixpkgs/blob/nixos-26.05/pkgs/by-name/th/throne/package.nix)
- [`throne.nix` из nixpkgs](https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/programs/throne.nix)
