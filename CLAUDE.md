# rig

Et personligt Arch + Hyprland-system. Repoet er kilden til hele systemet: Hvis en ændring ikke står her, overlever den ikke en geninstallation.

## Sådan er det skruet sammen

| Sti | Hvad |
|---|---|
| `install.sh` | Indgangen. Sender videre til `install/iso.sh` på ISO'en og ellers til `install/setup.sh` |
| `install/iso.sh` | Som root på ISO'en: disk, LUKS, btrfs, pacstrap |
| `install/chroot.sh` | Som root i det nye system: locale, bruger, bootloader |
| `install/setup.sh` | Som brugeren: Claude Code først, derefter skrivebordet. Kan køres igen |
| `packages/*.txt` | Alt, der er installeret, en pakke pr. linje |
| `config/<navn>/` | Symlinket til `~/.config/<navn>` |
| `bin/` | Symlinket til `~/.local/bin` |
| `shell/` | Symlinket til `~/.bashrc` og `~/.bash_profile` |
| `claude/` | Claudes globale instruktioner og indstillinger |
| `test/` | Tests, se nedenfor |

## Regler for ændringer

- **Ændr i `~/rig`, ikke i `~/.config`.** Det er det samme sted på grund af symlinks, men en ny fil skal oprettes her for at komme med.
- **En ny pakke skal i `packages/`.** Installér den og skriv den på listen i samme ændring, ellers forsvinder den ved næste installation.
- **Kun maskinen selv:** Tastatur, skærme og GPU hører til i `config/hypr/machine.lua`, som installeren skriver, og som git ignorerer.
- **Små commits.** Git er vejen tilbage, og brugeren skal kunne læse historikken.

## Hyprland

Vigtigt: Hyprland har skiftet config-sprog, og det meste, der står på nettet, er forældet.

- Configen er **Lua** (`config/hypr/hyprland.lua`). `hyprland.conf` virker ikke længere siden 0.57.
- API'et er `/usr/share/hypr/stubs/hl.meta.lua`, og wikien ligger på `https://wiki.hypr.land/configuring/` med små bogstaver.
- `hyprctl dispatch` tager Lua: `hyprctl dispatch 'hl.dsp.exit()'`. Den gamle `hyprctl dispatch exit` virker ikke.
- `hyprlock` og `hypridle` bruger stadig det gamle `.conf`-format.
- Kør `Hyprland --verify-config` efter hver ændring i configen.
- Sessionen startes med `start-hyprland` fra `shell/bash_profile`, uden display manager eller uwsm.

## Kendte huller

- **Klik på workspaces i Waybar virker ikke.** Waybar 0.15 sender stadig den gamle `dispatch`-syntaks. Det bliver løst i en nyere Waybar. Tastaturet virker.

## Tests

- `test/lint.sh`: shellcheck, pakkenavne og Hyprlands egen config-validering i en Arch-container.
- `.github/workflows/e2e.yml`: Installerer hele systemet fra en rigtig Arch-ISO i QEMU, booter det og tager et skærmbillede. Kør den, når du har ændret noget i `install/`, for fejl dér kan først ses, når disken er slettet.

Bash-scripts skal bestå `shellcheck`.
