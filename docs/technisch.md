# Technische documentatie (hassship)

Aanvulling op de [README](../README.md). Daar staan de basisstappen (sleutel maken,
`.env`, deployen, commit en push, terugdraaien, veelvoorkomende fouten). Hier staat wat
daar bewust niet in staat.

## Benodigde tools op de Mac
`ssh`, `scp` en `rsync` zijn standaard aanwezig. Verder: `python3` met PyYAML
(`pip3 install pyyaml`, of `brew install yq`) voor de syntaxcontrole en optioneel
`brew install shellcheck`.

## SSH-app op Home Assistant OS
Gebruikt wordt de app **Advanced SSH & Web Terminal**. Configuratie:

```yaml
ssh:
  username: root           # NIET hassio: die kan niet schrijven in /config
  password: ""             # leeg: alleen sleutels
  authorized_keys:
    - ssh-ed25519 AAAA... hass-deploy
  sftp: true               # nodig voor de scp-fallback
  compatibility_mode: false
  allow_agent_forwarding: false
  allow_remote_port_forwarding: false
  allow_tcp_forwarding: false
```

De configuratiemap is `/homeassistant`; `/config` is daar een symlink naar.
`scripts/check-connection.sh` detecteert het pad via `configuration.yaml`. Zet
`HASS_CONFIG_DIR` in `.env` als dat het verkeerde antwoord geeft.

### Hostkey verifiëren (verplicht)
De scripts gebruiken `StrictHostKeyChecking=yes`; verificatie wordt nooit uitgeschakeld.
Voeg de hostkey eenmalig toe **nadat je de fingerprint hebt vergeleken**:

```bash
ssh-keyscan -p 22 -t ed25519 homeassistant.local > /tmp/hass.key
ssh-keygen -lf /tmp/hass.key
cat /tmp/hass.key >> ~/.ssh/known_hosts
```

Vergelijk de fingerprint met die uit de webterminal van de SSH-app:

```bash
ssh-keygen -lf "$(find / -name ssh_host_ed25519_key.pub 2>/dev/null | head -1)"
```

## Dashboard registreren in `configuration.yaml`
Controleer eerst of er al een `lovelace:` staat (`scripts/check-connection.sh` toont dat).

- Geen `lovelace:` → voeg toe:
  ```yaml
  lovelace:
    dashboards:
      voorbeeld:             # URL /voorbeeld; de sleutel moet een streepje bevatten
        mode: yaml
        title: Voorbeeld
        icon: mdi:flask
        show_in_sidebar: true
        filename: dashboards/voorbeeld.yaml
  ```
- Wel een `lovelace:` → voeg alleen de entry onder het bestaande `dashboards:` toe.
  Zet **nooit** `mode: yaml` direct onder `lovelace:`: dat vervangt je bestaande standaarddashboard.

Controleer via Ontwikkelhulpmiddelen → YAML en herstart Home Assistant. Dat is alleen bij
de eerste registratie nodig; daarna volstaat verversen met Cmd+Shift+R.

## Een extra dashboard toevoegen
Kopieer `dashboards/voorbeeld.yaml` naar `dashboards/<naam>.yaml`, voeg een entry met
een unieke sleutel (met streepje) toe in `configuration.yaml` en herstart eenmalig.

## deploy.sh
```bash
./deploy.sh [--dry-run] [--backup] [--protected]
```
- Uploadt alleen `dashboards/*.yaml`. Het beschermde dashboard
  (`HASS_PROTECTED_DASHBOARD` in `.env`) wordt overgeslagen, behalve met `--protected` plus
  bevestiging.
- Valideert YAML vooraf en stopt bij elke mislukte controle.
- Vergelijkt sha256 lokaal en remote; alleen gewijzigde bestanden worden geüpload.
- Upload via `rsync` (tijdelijk bestand + rename) of anders `scp` + `mv`. Er wordt nooit
  iets op Home Assistant verwijderd.
- `--backup` bewaart de oude versie in `/config/dashboards/.backups/<tijdstempel>/`.

## Automations deployen
```bash
./deploy-automations.sh [--dry-run] [--backup] [--no-reload]
```
Uploadt `automations/*.yaml` naar `/config/automations/` (zelfde controles, sha256-diff en
atomaire upload als `deploy.sh`; verwijdert nooit iets). Elk bestand moet een **lijst** van
automations zijn; ids moeten uniek zijn. Bestanden die op `.disabled` eindigen worden
genegeerd.

### Eenmalig in `configuration.yaml`
Je kunt `automation:` maar één keer gebruiken. Staat er al `automation: !include automations.yaml`
(UI-automations), geef dan beide een eigen label:
```yaml
automation ui: !include automations.yaml
automation manual: !include_dir_merge_list automations/
```
Herstart Home Assistant daarna één keer. Het script waarschuwt als de verwijzing ontbreekt.
Automations die in de UI worden gemaakt blijven in `automations.yaml`; die beheert dit
project niet, zodat UI-wijzigingen niet worden overschreven.

### Automatisch herladen (optioneel)
Zet `HASS_TOKEN` (langlevende toegangstoken) en eventueel `HASS_URL` in `.env`. Na de upload
controleert het script de configuratie (`check_config`) en voert alleen bij een geldige
configuratie `automation.reload` uit. Zonder token upload je alleen en herlaad je zelf via
Ontwikkelhulpmiddelen > Acties > `automation.reload`.

## pull.sh
```bash
./pull.sh [--yes] [bestand.yaml ...]
```
Haalt remote `*.yaml` op, toont een diff en vraagt bevestiging. Lokale versies worden eerst
gebackupt in `.backups/local-<tijdstempel>/`. Staat een dashboard in storage-modus, dan
meldt het script dat er geen YAML-bestand is. Storage-dashboards staan als JSON in
`/config/.storage/lovelace*`; kopieer de inhoud via de ruwe configuratie-editor.

## Aanvullende foutmeldingen
| Melding | Oplossing |
|---|---|
| `configuration.yaml niet gevonden` | Zet `HASS_CONFIG_DIR` (`/config` of `/homeassistant`) |
| `rsync: --chmod ... invalid argument` | Oude scriptversie (macOS gebruikt openrsync); `git pull` |
| Dashboard verschijnt niet | Entry in `configuration.yaml` + herstart; de sleutel bevat een streepje |
