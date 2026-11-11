# hassship

🇳🇱 Nederlands · [🇬🇧 English](README.en.md)

> Verstuur je Home Assistant dashboards en automations vanuit Git via SSH.

Met dit project beheer je de dashboards en automations van je Home Assistant als
bestanden. Je past ze aan op je Mac of Windows-computer, probeert ze uit en bewaart ze
veilig op GitHub.

> Technische details staan in [docs/technisch.md](docs/technisch.md). Dit bestand is de
> eenvoudige uitleg.

---

## Wat is wat?

| Woord | Wat het betekent |
|---|---|
| **Dashboard** | Een scherm in Home Assistant met knoppen en kaarten (lampen, muziek, agenda). |
| **YAML-bestand** | Een tekstbestand waarin staat hoe het dashboard eruitziet. Staat in de map `dashboards/`. |
| **Deploy** | Je aangepaste bestand **naar Home Assistant sturen**, zodat je de wijziging echt ziet. |
| **Commit** | Een **opgeslagen moment** van je werk, met een korte beschrijving. Net een save-punt in een spel. |
| **Push** | Je opgeslagen momenten **naar GitHub sturen**, als back-up en om te delen. |
| **SSH-sleutel** | Een soort digitale sleutel waarmee je Mac Home Assistant binnenkomt, zonder wachtwoord. |

**Belangrijk:** een deploy en een commit/push zijn twee **losse** dingen.

- *Deploy* = je wijziging verschijnt in Home Assistant.
- *Commit + push* = je wijziging wordt bewaard op GitHub.

Het ene doet het andere niet automatisch.

> Een bestaand dashboard in de gebruikersinterface (storage-modus) raak je met dit project
> niet aan. Je werkt aan YAML-dashboards in `dashboards/`, zoals `dashboards/voorbeeld.yaml`.

---

## Eenmalig instellen

Dit doe je maar één keer. Kies eerst je computer.

### Stap 0: Voorbereiding op je computer

**Mac**

1. Open de app **Terminal** (zoek met Cmd+Spatie op "Terminal").
2. Installeer de hulpmiddelen. Vaak staat alles er al op. Controleer het zo:
   ```bash
   git --version
   python3 --version
   ```
   Staat er een foutmelding of vraagt de Mac om "command line tools" te installeren, klik dan op **Installeren**.
3. Installeer de YAML-controle:
   ```bash
   pip3 install pyyaml
   ```
4. Haal het project binnen:
   ```bash
   mkdir -p ~/git && cd ~/git
   git clone https://github.com/pimvd/hassship.git
   cd hassship
   ```

**Windows**

De scripts (`deploy.sh`) werken in een Linux-omgeving. Windows heeft die ingebouwd, via **WSL**. Je hoeft hiervoor niets te begrijpen van Linux: je typt dezelfde commando's als op de Mac.

1. Klik op Start, zoek **PowerShell**, klik rechts op **Als administrator uitvoeren** en typ:
   ```powershell
   wsl --install
   ```
   Start de computer opnieuw op als dat gevraagd wordt. Daarna opent **Ubuntu** en vraagt om een gebruikersnaam en wachtwoord. Kies er een.
2. Open voortaan voor alle commando's in deze handleiding de app **Ubuntu** (niet PowerShell).
3. Installeer de hulpmiddelen in Ubuntu:
   ```bash
   sudo apt update && sudo apt install -y git rsync openssh-client python3 python3-yaml netcat-openbsd
   ```
4. Haal het project binnen. Zet het in de Ubuntu-map (`~`), **niet** in `C:\`:
   ```bash
   mkdir -p ~/git && cd ~/git
   git clone https://github.com/pimvd/hassship.git
   cd hassship
   ```
5. Installeer in VS Code de extensie **WSL**. Open de projectmap daarna met:
   ```bash
   code .
   ```

> Waar in de rest van de handleiding "Terminal" staat, bedoelen we op Windows de app **Ubuntu**.

### Stap 1: Een SSH-sleutel maken

Typ in de Terminal (Mac) of Ubuntu (Windows):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hass_deploy -C "hass-deploy"
```

- Er wordt gevraagd om een wachtwoord (passphrase). Kies er een en onthoud het.
- Er ontstaan twee bestanden:
  - `~/.ssh/hass_deploy` is je **geheime** sleutel. Deel die **nooit** met iemand.
  - `~/.ssh/hass_deploy.pub` is je **publieke** sleutel. Die mag Home Assistant kennen.

Laat je publieke sleutel zien:

```bash
cat ~/.ssh/hass_deploy.pub
```

Kopieer de hele regel (begint met `ssh-ed25519`).

Laat je computer de sleutel onthouden, zodat je het wachtwoord niet steeds hoeft te typen:

- **Mac:**
  ```bash
  ssh-add --apple-use-keychain ~/.ssh/hass_deploy
  ```
- **Windows (Ubuntu):** dit geldt voor de huidige Ubuntu-sessie. Doe het opnieuw als je Ubuntu opnieuw opent.
  ```bash
  eval "$(ssh-agent -s)"
  ssh-add ~/.ssh/hass_deploy
  ```

### Stap 2: De sleutel in Home Assistant zetten

Dit is hetzelfde op Mac en Windows.

1. Open Home Assistant → **Instellingen → Apps** → **Advanced SSH & Web Terminal** → **Configuratie**.
2. Vul in:
   - **username:** `root`
   - **password:** leeg laten
   - **authorized_keys:** voeg je gekopieerde regel toe
3. Klik **Opslaan** en daarna **Herstarten** van de app.

### Stap 3: Het projectbestand `.env` maken

In de projectmap (`~/git/hassship`):

```bash
cp .env.example .env
```

Open `.env` en zet `HASS_HOST` op het adres van jouw Home Assistant (standaard
`homeassistant.local`). De gebruiker is `root`.

### Stap 4: Controleren of alles werkt

```bash
scripts/check-connection.sh
```

Je ziet groene **OK**-regels. Staat er een rode **FOUT**? Kijk onderaan bij *Hulp bij problemen*.

> De eerste keer weigert het script mogelijk met "Hostkey onbekend". Dat is een
> beveiliging. Zie [docs/technisch.md](docs/technisch.md) voor hoe je de hostkey veilig
> toevoegt.

---

## Een dashboard aanpassen en deployen

### 1. Aanpassen
Open de map in **VS Code** en pas `dashboards/voorbeeld.yaml` aan. Sla op met Cmd+S.

### 2. Eerst kijken wat er zou gebeuren (veilig)
```bash
./deploy.sh --dry-run
```
Dit **wijzigt niets**. Je ziet alleen welke bestanden verstuurd zouden worden.

### 3. Echt deployen
```bash
./deploy.sh
```
Wil je een reservekopie van de oude versie op Home Assistant?
```bash
./deploy.sh --backup
```

### 4. Bekijken
Ga naar je dashboard in Home Assistant en ververs de pagina met **Cmd+Shift+R**.

Je kunt `./deploy.sh` zo vaak draaien als je wilt. Zijn er geen wijzigingen, dan doet het niets.

---

## Automations deployen

Automations (YAML-bestanden in `automations/`) deploy je met een eigen script:

```bash
./deploy-automations.sh --dry-run   # eerst kijken
./deploy-automations.sh --backup    # echt deployen, met reservekopie
```

Elk bestand bevat een **lijst** van automations (begin elke automation met `- `). Zie
`automations/voorbeeld.yaml.disabled`; hernoem naar `.yaml` om het te gebruiken.

**Eenmalig:** zet in `configuration.yaml` (en herstart Home Assistant één keer):
```yaml
automation manual: !include_dir_merge_list automations/
```
Staat er al `automation: !include automations.yaml`? Geef die dan ook een label, bijvoorbeeld
`automation ui:`.

**Automatisch herladen (optioneel):** maak in Home Assistant een *langlevende toegangstoken*
(profiel → Beveiliging) en zet die in `.env` als `HASS_TOKEN=...`. Het script controleert dan
de configuratie en laadt de automations direct opnieuw. Zonder token herlaad je zelf via
Ontwikkelhulpmiddelen → Acties → `automation.reload`.

Meer details: [docs/technisch.md](docs/technisch.md).

---

## Je werk bewaren op GitHub (commit en push)

Doe dit als je tevreden bent met je wijziging.

### 1. Kijken wat er veranderd is
```bash
git status
```

### 2. Wijzigingen klaarzetten
```bash
git add .
```

### 3. Opslaan met een beschrijving (commit)
```bash
git commit -m "Korte omschrijving van wat je deed"
```
Voorbeeld: `git commit -m "Gordijnknop groter gemaakt"`

### 4. Naar GitHub sturen (push)
```bash
git push
```

### Staat er een foutmelding bij `git push`?
Dan heeft iemand anders (of jij op een andere computer) intussen iets nieuws gepusht.
Haal dat eerst op en push dan opnieuw:

```bash
git pull --rebase
git push
```

**Kort samengevat:** `git add .` → `git commit -m "..."` → `git push`

---

## Iets terugdraaien

- **Je wijziging nog niet gecommit, en je wilt terug naar de laatste opgeslagen versie:**
  ```bash
  git checkout -- dashboards/
  ./deploy.sh
  ```
- **Het is al gedeployed en je had `--backup` gebruikt:** de oude versie staat op Home
  Assistant in `/config/dashboards/.backups/`.
- **Het gaat echt mis:** je dashboards in de gebruikersinterface zijn nooit aangeraakt en werken gewoon door.

---

## Hulp bij problemen

| Je ziet | Wat te doen |
|---|---|
| `.env ontbreekt` | Voer stap 3 uit: `cp .env.example .env` |
| `SSH-sleutel niet gevonden` | Voer stap 1 uit (sleutel maken). |
| `SSH-authenticatie geweigerd` | De publieke sleutel staat niet goed in de SSH-app, of de username is niet `root`. Doe stap 2 opnieuw en herstart de app. |
| `SSH-authenticatie geweigerd`, terwijl de sleutel wel goed in Home Assistant staat (in het logboek van de SSH-app staat `Accepted key ... Postponed publickey`) | De sleutel heeft een wachtwoord en je Mac heeft hem niet onthouden (na een herstart of nieuwe Terminal). Voer uit: `ssh-add --apple-use-keychain ~/.ssh/hass_deploy` (Windows: zie stap 1) en probeer opnieuw. |
| `Hostkey onbekend of gewijzigd` | Zie [docs/technisch.md](docs/technisch.md). |
| `Poort 22 niet bereikbaar` | Staat de SSH-app aan? Ben je thuis of via VPN? |
| `niet schrijfbaar` | De username in de SSH-app moet `root` zijn (niet `hassio`). |
| `Geen YAML-validator` | Mac: `pip3 install pyyaml`. Windows (Ubuntu): `sudo apt install python3-yaml` |
| Wijziging niet zichtbaar | Ververs met Cmd+Shift+R (Windows: Ctrl+Shift+R). |
| `git push` geweigerd | Voer uit: `git pull --rebase` en daarna `git push`. |
