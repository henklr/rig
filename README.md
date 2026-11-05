# rig

Mit eget Linux-system: Arch og Hyprland, med Claude Code som systemets copilot. Én kommando fra en ren Arch til et kørende skrivebord. Resten bygger jeg sammen med Claude på maskinen.

## Installation

Slå Secure Boot fra i BIOS, og boot Arch-ISO'en i UEFI-tilstand. Vælg dansk tastatur, hvis du vil have `-` og `|` de rigtige steder:

```bash
loadkeys dk
```

På trådløst net skal du forbinde først:

```bash
iwctl station wlan0 connect "Netværksnavn"
```

Kør så:

```bash
curl -fsSL https://github.com/henklr/rig/raw/main/install.sh | bash
```

Du bliver spurgt om brugernavn, adgangskode og hvilken disk, Arch skal på, og den disk bliver **slettet helt**. Den samme adgangskode bruges til diskkryptering, sudo og låseskærm. Du skal skrive diskens navn for at bekræfte. Bagefter kører resten af sig selv. Efter genstart møder du en login-skærm med dit brugernavn. Skriv adgangskoden, så starter Hyprland med Claude på skærmen, klar til at logge ind på din konto.

Login-skærmen er i virkeligheden diskens adgangskode, tegnet så den ligner låseskærmen. Derfor er der kun én kode, og krypteringen er lige så stærk. Der er ingen bootmenu, men du kan holde en tast nede under opstart for at se den. Installerer du uden kryptering, logger du ind i konsollen som normalt.

Har du allerede installeret Arch, virker den samme kommando. Den rører ikke din disk og lægger kun skrivebordet ovenpå.

## Det får du

| Hvad | Valg |
|---|---|
| Disk | LUKS2-kryptering, btrfs med snapshots før og efter hver pacman-kørsel |
| Boot | systemd-boot, zram som swap |
| Skrivebord | Hyprland, Waybar, Fuzzel, Mako, Hyprlock, Hypridle |
| Programmer | Alacritty, Brave, Nemo, Thunderbird, Neovim, tmux |
| Lyd og net | PipeWire, NetworkManager, Bluetooth |
| AUR | yay, Brave |
| Copilot | Claude Code, installeret før alt andet på grundsystemet |

Programmer, vinduer og taster kommer fra mine gamle dotfiles. Resten skal bygges nu.

## Taster

| Tast | Handling |
|---|---|
| `Super + A` | **Vis eller skjul Claude** |
| `Super + Return` | Terminal |
| `Super + Space` | Programmenu |
| `Super + B` / `F` | Brave / filer |
| `Super + Q` | Luk vindue |
| `Super + Shift + F` | Fuld skærm |
| `Super + V` | Flydende vindue |
| `Super + P` / `J` | Pseudotile / skift split |
| `Super + L` | Lås skærmen |
| `Super + M` | rig-menuen, også knappen øverst til højre |
| `Super + piletast` | Flyt fokus |
| `Super + Shift + piletast` | Byt vinduer |
| `Super + S` / `Super + Shift + S` | Vis scratchpad / flyt vindue dertil |
| `Super + 1-0` | Skift workspace |
| `Super + Shift + 1-0` | Flyt vindue til workspace |
| `Super + Shift + V` | Udklipsholder-historik |
| `Print` | Skærmbillede af et område til udklipsholderen |
| `Super + Shift + E` | Genstart skrivebordet |

## Claude som copilot

Claude kører i `~/rig`, så systemets egen konfiguration er det, den arbejder på. Det hele er symlinket derfra til `~/.config`, så alt, I ændrer, ligger i git.

- **Først på maskinen:** Claude installeres før skrivebordet. Går noget galt bagefter, er den der allerede og kan hjælpe, også på en ren konsol.
- **Root kræver din godkendelse:** Claude bruger `sudo -A`, som viser en popup med kommandoen. Der er ingen adgangskodefri root.
- **Fortrydelse:** snapper tager snapshots af systemet, og git dækker konfigurationen.

Reglerne, Claude arbejder efter, står i [CLAUDE.md](CLAUDE.md) og [claude/CLAUDE.md](claude/CLAUDE.md).

## Vedligehold

Klik på tandhjulet øverst til højre, eller tryk `Super + M`, og vælg **Opdater**. Det henter det nyeste fra GitHub, opdaterer systemet og spørger om genstart, hvis det er nødvendigt. Menuen kan også genstarte og slukke maskinen.

Installeren kan også køres direkte, for eksempel fra en konsol, hvis skrivebordet ikke starter:

```bash
~/rig/install.sh
```

## Test

`test/lint.sh` tjekker scripts, pakkenavne og configs ved hvert push og hver mandag mod de nyeste pakker. GitHub-workflowet **e2e** installerer hele systemet fra en rigtig ISO i en virtuel maskine, booter det og tager et skærmbillede.
