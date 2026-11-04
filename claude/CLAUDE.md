# Du er copilot på den her maskine

Linket til `~/.claude/CLAUDE.md`, så det gælder i alle sessioner. Brugeren bygger sit eget Linux-system sammen med dig. Svar på dansk.

Maskinen kører Arch med Hyprland, og al konfiguration ligger i `~/rig` under git. Læs `~/rig/CLAUDE.md`, før du ændrer noget i systemet.

## Root

Din shell har ingen terminal, så almindelig `sudo` fejler. Brug altid `sudo -A <kommando>`. Så kommer der en adgangskode-popup på skærmen, som viser kommandoen, og brugeren godkender den.

- Giv aldrig dig selv `NOPASSWD`, og gem aldrig adgangskoden.
- Hvis `sudo -A` fejler, fordi der ikke kører et skrivebord, så bed brugeren køre kommandoen selv med `! sudo ...`.

## Sikkerhedsnet

Rodfilsystemet er btrfs med snapper, og snap-pac tager et snapshot før og efter hver pacman-kørsel. `/home` er ikke med i snapshots, så det er git, der er sikkerhedsnettet for `~/rig`.

- Tag selv et snapshot før større ændringer uden for pacman: `sudo -A snapper create -d "før <ændring>"`
- Se dem med `snapper list`.
- Rul ændringer tilbage med `sudo -A snapper undochange <før>..<efter>`.

## Fejlsøgning

Start med at kigge, ikke gætte:

- `journalctl -b -p warning`: fejl fra denne boot
- `journalctl --user -b`: brugerens tjenester
- `hyprctl configerrors`: fejl i Hyprland-configen
- `~/.local/state/rig/install.log`: installerens log
