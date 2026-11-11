# hassship

[🇳🇱 Nederlands](README.md) · 🇬🇧 English

> Ship your Home Assistant dashboards and automations from Git over SSH.

Manage your Home Assistant YAML dashboards and automations as files in Git. Edit them on your
Mac or PC, check what would change, deploy with one command, and keep everything versioned on
GitHub.

- **Safe by default:** `--dry-run` shows what would happen; nothing is ever deleted on Home Assistant.
- **Validates first:** YAML syntax is checked locally before anything is uploaded.
- **Atomic uploads:** files go up as a temp file and are renamed, so Home Assistant never sees a half-written file.
- **Only changed files** are uploaded (sha256 comparison).
- **Optional backups** of the remote version before overwriting (`--backup`).
- **Auto reload (optional):** with an access token, automations are reloaded after the config check passes.

> The scripts' output and the detailed guides ([docs/technisch.md](docs/technisch.md)) are in Dutch.

## Requirements

- Home Assistant OS (or another setup) with the **Advanced SSH & Web Terminal** add-on.
- A Mac, Linux machine, or Windows with WSL, with `git`, `ssh`, `scp`, `python3` and PyYAML (`pip3 install pyyaml`).

## Setup (once)

1. **Clone:** `git clone https://github.com/pimvd/hassship.git && cd hassship`
2. **Create an SSH key:**
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/hass_deploy -C "hass-deploy"
   ssh-add --apple-use-keychain ~/.ssh/hass_deploy   # macOS; on Linux: ssh-add ~/.ssh/hass_deploy
   ```
   If the key has a passphrase it must be loaded in your ssh-agent, because the scripts run
   in non-interactive mode and never ask for a passphrase.
3. **Add the public key** (`cat ~/.ssh/hass_deploy.pub`) in the add-on configuration:
   ```yaml
   ssh:
     username: root
     password: ""
     authorized_keys:
       - ssh-ed25519 AAAA... hass-deploy
     sftp: true
   ```
   Save and restart the add-on.
4. **Configure:** `cp .env.example .env` and set `HASS_HOST` to your Home Assistant address.
5. **Verify the host key** once (see [docs/technisch.md](docs/technisch.md)), then run
   `scripts/check-connection.sh`. All lines should be green.

## Dashboards

Put YAML dashboards in `dashboards/` and register each one in `configuration.yaml` (one-time
entry plus a restart; see [docs/technisch.md](docs/technisch.md)).

```bash
./deploy.sh --dry-run    # look first
./deploy.sh --backup     # deploy, keeping the old remote version
./pull.sh                # fetch remote dashboards (shows a diff first)
```

Set `HASS_PROTECTED_DASHBOARD` in `.env` to a file name you want `deploy.sh` to skip unless you
pass `--protected` (and confirm).

## Automations

Put automation files in `automations/`. Each file must contain a **list** of automations
(start each with `- `); see `automations/voorbeeld.yaml.disabled` and rename it to `.yaml` to use it.

One-time, in `configuration.yaml` (then restart Home Assistant once):

```yaml
automation manual: !include_dir_merge_list automations/
```

If you already have `automation: !include automations.yaml`, give that one a label too, e.g.
`automation ui:`. Automations created in the UI stay in `automations.yaml` and are never touched.

```bash
./deploy-automations.sh --dry-run
./deploy-automations.sh --backup
```

To reload automatically after a deploy, create a **long-lived access token** (profile →
Security) and set `HASS_TOKEN=...` in `.env`. The script then runs Home Assistant's config
check and, only if it is valid, calls `automation.reload`. Without a token you reload manually
(Developer tools → Actions → `automation.reload`).

## Troubleshooting

| You see | What to do |
|---|---|
| `.env ontbreekt` | `cp .env.example .env` |
| `SSH-authenticatie geweigerd` | Check the public key and `username: root` in the add-on, restart it. |
| Same, but the add-on log shows `Accepted key … Postponed publickey` | Your key has a passphrase and isn't loaded: run `ssh-add` for the key. |
| `Hostkey onbekend of gewijzigd` | Add the verified host key to `known_hosts` (see docs). |
| `niet schrijfbaar` | The add-on username must be `root`, not `hassio`. |
| `Geen YAML-validator` | `pip3 install pyyaml` |

## License

[MIT](LICENSE)
