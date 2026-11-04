# rig

Mit eget Linux-system: Arch og Hyprland, med Claude Code som systemets copilot. Én kommando fra en ren Arch til et kørende skrivebord. Resten bygger jeg sammen med Claude på maskinen.

## Installation

Boot Arch-ISO'en i UEFI-tilstand, og vælg dansk tastatur, hvis du vil have `-` og `|` de rigtige steder:

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

Du bliver spurgt om brugernavn, adgangskode og hvilken disk, Arch skal på, og den disk bliver **slettet helt**. Du skal skrive diskens navn for at bekræfte. Bagefter kører resten af sig selv. Log ind efter genstart, så starter Hyprland med Claude på skærmen, klar til at logge ind på din konto.

Har du allerede installeret Arch, virker den samme kommando. Den rører ikke din disk og lægger kun skrivebordet ovenpå.

## Det får du

| Hvad | Valg |
|---|---|
| Disk | LUKS2-kryptering, btrfs med snapshots før og efter hver pacman-kørsel |
| Boot | systemd-boot, zram som swap |
| Skrivebord | Hyprland, Waybar, Fuzzel, Mako, Hyprlock, Hypridle |
| Programmer | Ghostty, Firefox, Thunar, Neovim, tmux |
| Lyd og net | PipeWire, NetworkManager, Bluetooth |
| AUR | yay |
| Copilot | Claude Code, installeret før alt andet på grundsystemet |

Der er med vilje ikke meget tema eller opsætning. Det er det, der skal bygges nu.

## Taster

| Tast | Handling |
|---|---|
| `Super + A` | **Vis eller skjul Claude** |
| `Super + Return` | Terminal |
| `Super + Space` | Programmenu |
| `Super + B` / `E` | Firefox / filer |
| `Super + Q` | Luk vindue |
| `Super + F` / `V` | Fuld skærm / flydende vindue |
| `Super + L` | Lås skærmen |
| `Super + 1-0` | Skift workspace |
| `Super + Shift + 1-0` | Flyt vindue til workspace |
| `Super + Shift + V` | Udklipsholder-historik |
| `Print` | Skærmbillede af et område til udklipsholderen |
| `Super + Shift + E` | Log ud |

## Claude som copilot

Claude kører i `~/rig`, så systemets egen konfiguration er det, den arbejder på. Det hele er symlinket derfra til `~/.config`, så alt, I ændrer, ligger i git.

- **Først på maskinen:** Claude installeres før skrivebordet. Går noget galt bagefter, er den der allerede og kan hjælpe, også på en ren konsol.
- **Root kræver din godkendelse:** Claude bruger `sudo -A`, som viser en popup med kommandoen. Der er ingen adgangskodefri root.
- **Fortrydelse:** snapper tager snapshots af systemet, og git dækker konfigurationen.

Reglerne, Claude arbejder efter, står i [CLAUDE.md](CLAUDE.md) og [claude/CLAUDE.md](claude/CLAUDE.md).

## Vedligehold

Installeren kan køres igen. Det er også sådan, du reparerer eller opdaterer:

```bash
~/rig/install.sh
```

## Test

`test/lint.sh` tjekker scripts, pakkenavne og configs. GitHub-workflowet **e2e** installerer hele systemet fra en rigtig ISO i en virtuel maskine, booter det og tager et skærmbillede.
