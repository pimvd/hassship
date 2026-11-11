# Technical documentation (hassship)

Supplements the [README](../README.md). The README has the basic steps (creating a key,
`.env`, deploying, commit and push, undoing, common errors). This file covers what it
deliberately leaves out.

## Required tools on the Mac
`ssh`, `scp` and `rsync` are installed by default. Also needed: `python3` with PyYAML
(`pip3 install pyyaml`, or `brew install yq`) for the syntax check, and optionally
`brew install shellcheck`.

## SSH add-on on Home Assistant OS
The add-on **Advanced SSH & Web Terminal** is used. Configuration:

```yaml
ssh:
  username: root           # NOT hassio: it cannot write to /config
  password: ""             # empty: keys only
  authorized_keys:
    - ssh-ed25519 AAAA... hass-deploy
  sftp: true               # needed for the scp fallback
  compatibility_mode: false
  allow_agent_forwarding: false
  allow_remote_port_forwarding: false
  allow_tcp_forwarding: false
```

The config directory is `/homeassistant`; `/config` is a symlink to it there.
`scripts/check-connection.sh` detects the path via `configuration.yaml`. Set
`HASS_CONFIG_DIR` in `.env` if that gives the wrong answer.

### Passphrase-protected keys
The scripts run ssh with `BatchMode=yes`, so they never prompt for a passphrase. A key with a
passphrase must be loaded in your ssh-agent (`ssh-add`). If it isn't, the add-on log shows
`Accepted key ... Postponed publickey` followed by a closed connection, and the script reports
`SSH authentication refused`. Alternatively use a dedicated key without a passphrase.

### Verify the host key (required)
The scripts use `StrictHostKeyChecking=yes`; verification is never disabled. Add the host key
once **after comparing the fingerprint**:

```bash
ssh-keyscan -p 22 -t ed25519 homeassistant.local > /tmp/hass.key
ssh-keygen -lf /tmp/hass.key
cat /tmp/hass.key >> ~/.ssh/known_hosts
```

Compare the fingerprint with the one from the web terminal of the SSH add-on:

```bash
ssh-keygen -lf "$(find / -name ssh_host_ed25519_key.pub 2>/dev/null | head -1)"
```

## Registering a dashboard in `configuration.yaml`
First check whether a `lovelace:` section already exists (`scripts/check-connection.sh` shows it).

- No `lovelace:` → add:
  ```yaml
  lovelace:
    dashboards:
      example:               # URL /example; the key must contain a hyphen
        mode: yaml
        title: Example
        icon: mdi:flask
        show_in_sidebar: true
        filename: dashboards/example.yaml
  ```
- Already a `lovelace:` → only add the entry under the existing `dashboards:`.
  **Never** put `mode: yaml` directly under `lovelace:`: that replaces your existing default dashboard.

Check via Developer tools → YAML and restart Home Assistant. This is only needed for the
first registration; afterwards refreshing with Cmd+Shift+R is enough.

> Note: a dashboard key must contain a hyphen (for example `my-example`), or Home Assistant rejects it.

## Adding another dashboard
Copy `dashboards/example.yaml` to `dashboards/<name>.yaml`, add an entry with a unique key
(with a hyphen) in `configuration.yaml`, and restart once.

## deploy.sh
```bash
./deploy.sh [--dry-run] [--backup] [--protected]
```
- Only uploads `dashboards/*.yaml`. The protected dashboard (`HASS_PROTECTED_DASHBOARD` in
  `.env`) is skipped, except with `--protected` plus confirmation.
- Validates YAML first and stops at every failed check.
- Compares sha256 locally and remotely; only changed files are uploaded.
- Uploads via `rsync` (temp file + rename) or else `scp` + `mv`. Nothing is ever deleted on
  Home Assistant.
- `--backup` keeps the old version in `/config/dashboards/.backups/<timestamp>/`.

## Deploying automations, scripts and scenes
```bash
./deploy-config.sh [--dry-run] [--backup] [--no-reload] [--prune] [automations|scripts|scenes ...]
```
Without a type, every kind that has files is deployed. `./deploy-automations.sh` is a shortcut
for `./deploy-config.sh ... automations`.

| Kind | Local folder | On Home Assistant | Each file contains |
|---|---|---|---|
| Automations | `automations/` | `/config/automations/` | a **list** (`- id: ...`) |
| Scripts | `ha-scripts/` | `/config/ha-scripts/` | a **map** keyed by script name (`my_script:`) |
| Scenes | `ha-scenes/` | `/config/ha-scenes/` | a **list** of scenes |

(The folder is `ha-scripts` because `scripts/` already holds this project's helper scripts.)

Same checks, sha256 diff and atomic upload as `deploy.sh`. Script names, automation ids and
scene ids must be unique across all files of the same kind. Files ending in `.disabled` are
ignored. A file deleted locally stays on Home Assistant unless you use `--prune` (asks for
confirmation; combine with `--backup` for a copy). The folder names on the server can be
changed with `HASS_AUTOMATION_SUBDIR`, `HASS_SCRIPT_SUBDIR` and `HASS_SCENE_SUBDIR` in `.env`.

### One-time in `configuration.yaml`
You can only use each domain key (`automation:`, `script:`, `scene:`) once, so give the UI file
and the folder each their own label:
```yaml
automation ui: !include automations.yaml
automation manual: !include_dir_merge_list automations/
script ui: !include scripts.yaml
script manual: !include_dir_merge_named ha-scripts/
scene ui: !include scenes.yaml
scene manual: !include_dir_merge_list ha-scenes/
```
Restart Home Assistant once afterwards. The script warns if a reference is missing. Home
Assistant fails its config check if a folder doesn't exist, so deploy at least once (which
creates the folders) before restarting.

### What does git own, and what does the UI own?
Everything in `automations/`, `ha-scripts/` and `ha-scenes/` is owned by git. Don't edit those
in the UI: scripts and scenes loaded from a folder have no edit button there, and a deploy
overwrites manual changes on the server. Things you still create in the UI end up in
`automations.yaml`, `scripts.yaml` and `scenes.yaml`; this project doesn't manage those.

### Moving existing scripts and scenes into git
A one-time migration, in this order (it avoids defining anything twice):
1. Copy `scripts.yaml` and `scenes.yaml` from the server and split them into
   `ha-scripts/<name>.yaml` (one script per file) and `ha-scenes/<name>.yaml`. Check that the
   conversion changes nothing (reload all files and compare with the original).
2. `./deploy-config.sh --backup --no-reload` (creates the folders).
3. On the server: back up `scripts.yaml`, `scenes.yaml` and `configuration.yaml`; replace the
   content of `scripts.yaml` with `{}` and of `scenes.yaml` with `[]` (otherwise everything is
   defined twice); update `configuration.yaml` as above.
4. Check the configuration (Developer tools > YAML) and restart Home Assistant.

Entity ids stay the same (`script.<key>`, `scene.<name>`), so dashboards and automations need
no changes.

### Automatic reload (optional)
Set `HASS_TOKEN` (long-lived access token) and optionally `HASS_URL` in `.env`. After the
upload the script runs the configuration check (`check_config`) and only if it is valid runs
`automation.reload`, `script.reload` and/or `scene.reload` (only for the kinds that changed).
Without a token you only upload and reload yourself via Developer tools > Actions.

## pull.sh
```bash
./pull.sh [--yes] [file.yaml ...]
```
Fetches remote `*.yaml`, shows a diff and asks for confirmation. Local versions are backed up
first in `.backups/local-<timestamp>/`. If a dashboard is in storage mode, the script reports
that there is no YAML file. Storage dashboards are stored as JSON in
`/config/.storage/lovelace*`; copy the contents via the raw configuration editor.

## Additional error messages
| Message | Fix |
|---|---|
| `configuration.yaml not found` | Set `HASS_CONFIG_DIR` (`/config` or `/homeassistant`) |
| `rsync: --chmod ... invalid argument` | Old script version (macOS uses openrsync); `git pull` |
| Dashboard doesn't appear | Entry in `configuration.yaml` + restart; the key contains a hyphen |
