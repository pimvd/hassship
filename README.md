# hassship

> Ship your Home Assistant dashboards and automations from Git over SSH.

Manage your Home Assistant YAML dashboards and automations as files. Edit them on your Mac
or PC, check what would change, deploy with one command, and keep everything versioned on
GitHub.

- **Safe by default:** `--dry-run` shows what would happen; nothing is ever deleted on Home Assistant.
- **Validates first:** YAML syntax is checked locally before anything is uploaded.
- **Atomic uploads:** files go up as a temp file and are renamed, so Home Assistant never sees a half-written file.
- **Only changed files** are uploaded (sha256 comparison).
- **Optional backups** of the remote version before overwriting (`--backup`).
- **Auto reload (optional):** with an access token, automations are reloaded after the config check passes.

Technical details are in [docs/technical.md](docs/technical.md). This file is the simple guide.

---

## What is what?

| Term | What it means |
|---|---|
| **Dashboard** | A screen in Home Assistant with buttons and cards (lights, music, calendar). |
| **Automation** | A rule in Home Assistant ("when X happens, do Y"). |
| **YAML file** | A text file describing how a dashboard or automation looks. Lives in `dashboards/` or `automations/`. |
| **Deploy** | **Sending** your edited file **to Home Assistant** so you actually see the change. |
| **Commit** | A **saved moment** of your work with a short description, like a save point in a game. |
| **Push** | **Sending** your commits **to GitHub**, as a backup and to share. |
| **SSH key** | A digital key that lets your computer into Home Assistant without a password. |

**Important:** a deploy and a commit/push are two **separate** things.

- *Deploy* = your change shows up in Home Assistant.
- *Commit + push* = your change is saved on GitHub.

One does not do the other automatically.

> Dashboards that you manage in the Home Assistant UI (storage mode) are never touched by
> this project. You work on YAML dashboards in `dashboards/`, such as `dashboards/example.yaml`.

---

## One-time setup

Pick your computer first.

### Step 0: Prepare your computer

**Mac**

1. Open **Terminal** (search with Cmd+Space).
2. Check the tools (they are usually installed already):
   ```bash
   git --version
   python3 --version
   ```
   If you get an error, or the Mac asks to install the "command line tools", click **Install**.
3. Install the YAML check:
   ```bash
   pip3 install pyyaml
   ```
4. Get the project:
   ```bash
   mkdir -p ~/git && cd ~/git
   git clone https://github.com/pimvd/hassship.git
   cd hassship
   ```

**Windows**

The scripts (`deploy.sh`) need a Linux environment. Windows has one built in, called **WSL**.
You don't need to know Linux: you type the same commands as on a Mac.

1. Click Start, search **PowerShell**, right-click **Run as administrator** and type:
   ```powershell
   wsl --install
   ```
   Restart if asked. **Ubuntu** then opens and asks for a user name and password. Pick any.
2. From now on, use the app **Ubuntu** (not PowerShell) for all commands in this guide.
3. Install the tools in Ubuntu:
   ```bash
   sudo apt update && sudo apt install -y git rsync openssh-client python3 python3-yaml netcat-openbsd
   ```
4. Get the project. Put it in the Ubuntu folder (`~`), **not** in `C:\`:
   ```bash
   mkdir -p ~/git && cd ~/git
   git clone https://github.com/pimvd/hassship.git
   cd hassship
   ```
5. In VS Code, install the **WSL** extension, then open the project folder with:
   ```bash
   code .
   ```

> Wherever this guide says "Terminal", on Windows that means the **Ubuntu** app.

### Step 1: Create an SSH key

Type in Terminal (Mac) or Ubuntu (Windows):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hass_deploy -C "hass-deploy"
```

- You are asked for a passphrase. Choose one and remember it.
- Two files are created:
  - `~/.ssh/hass_deploy` is your **secret** key. **Never** share it.
  - `~/.ssh/hass_deploy.pub` is your **public** key. Home Assistant may know this one.

Show your public key:

```bash
cat ~/.ssh/hass_deploy.pub
```

Copy the whole line (it starts with `ssh-ed25519`).

Let your computer remember the key, so you don't have to type the passphrase every time.
The scripts run non-interactively and **never ask for a passphrase**, so this step is required:

- **Mac:**
  ```bash
  ssh-add --apple-use-keychain ~/.ssh/hass_deploy
  ```
- **Windows (Ubuntu):** this applies to the current Ubuntu session. Repeat it when you reopen Ubuntu.
  ```bash
  eval "$(ssh-agent -s)"
  ssh-add ~/.ssh/hass_deploy
  ```

### Step 2: Put the key in Home Assistant

Same on Mac and Windows.

1. Open Home Assistant → **Settings → Add-ons** → **Advanced SSH & Web Terminal** → **Configuration**.
2. Fill in:
   - **username:** `root`
   - **password:** leave empty
   - **authorized_keys:** add the line you copied
3. Click **Save**, then **Restart** the add-on.

### Step 3: Create the project file `.env`

In the project folder:

```bash
cp .env.example .env
```

Open `.env` and set `HASS_HOST` to the address of your Home Assistant (default
`homeassistant.local`). The user is `root`.

### Step 4: Check that everything works

```bash
scripts/check-connection.sh
```

You should see green **OK** lines. A red **ERROR**? See *Troubleshooting* below.

> The first time the script may refuse with "Host key unknown". That is a security feature.
> See [docs/technical.md](docs/technical.md) for how to add the host key safely.

---

## Edit and deploy a dashboard

### 1. Edit
Open the folder in **VS Code** and edit `dashboards/example.yaml`. Save with Cmd+S.

### 2. Look first (safe)
```bash
./deploy.sh --dry-run
```
This **changes nothing**. You only see which files would be sent.

### 3. Deploy for real
```bash
./deploy.sh
```
Want a backup of the old version on Home Assistant?
```bash
./deploy.sh --backup
```

### 4. View
Open your dashboard in Home Assistant and refresh the page with **Cmd+Shift+R**.

You can run `./deploy.sh` as often as you like. If nothing changed, it does nothing.

A new dashboard must be registered once in `configuration.yaml`, followed by one restart
(see [docs/technical.md](docs/technical.md)).

---

## Deploy automations

Automations (YAML files in `automations/`) have their own script:

```bash
./deploy-automations.sh --dry-run   # look first
./deploy-automations.sh --backup    # deploy for real, with a backup
```

Every file contains a **list** of automations (start each automation with `- `). See
`automations/example.yaml.disabled`; rename it to `.yaml` to use it.

**One-time:** add this to `configuration.yaml` (and restart Home Assistant once):
```yaml
automation manual: !include_dir_merge_list automations/
```
Already have `automation: !include automations.yaml`? Give that one a label too, for example
`automation ui:`. Automations you create in the UI stay in `automations.yaml` and are never touched.

**Automatic reload (optional):** create a *long-lived access token* in Home Assistant
(profile → Security) and put it in `.env` as `HASS_TOKEN=...`. The script then runs Home
Assistant's config check and, only if it is valid, reloads the automations. Without a token
you reload manually via Developer tools → Actions → `automation.reload`.

More details: [docs/technical.md](docs/technical.md).

---

## Save your work on GitHub (commit and push)

Do this when you are happy with your change.

### 1. See what changed
```bash
git status
```

### 2. Stage the changes
```bash
git add .
```

### 3. Save with a description (commit)
```bash
git commit -m "Short description of what you did"
```
Example: `git commit -m "Made the curtain button bigger"`

### 4. Send to GitHub (push)
```bash
git push
```

### Error on `git push`?
Someone else (or you on another computer) pushed something new in the meantime. Fetch that
first, then push again:

```bash
git pull --rebase
git push
```

**In short:** `git add .` → `git commit -m "..."` → `git push`

---

## Undo something

- **Your change is not committed yet and you want the last saved version back:**
  ```bash
  git checkout -- dashboards/
  ./deploy.sh
  ```
- **It's already deployed and you used `--backup`:** the old version is on Home Assistant in
  `/config/dashboards/.backups/` (automations: `/config/automations/.backups/`).
- **It really goes wrong:** dashboards you manage in the UI were never touched and keep working.

---

## Troubleshooting

| You see | What to do |
|---|---|
| `.env is missing` | Do step 3: `cp .env.example .env` |
| `SSH key not found` | Do step 1 (create the key). |
| `SSH authentication refused` | The public key isn't set correctly in the SSH add-on, or the username isn't `root`. Redo step 2 and restart the add-on. |
| `SSH authentication refused`, while the key is correct in Home Assistant (the add-on log shows `Accepted key ... Postponed publickey`) | The key has a passphrase and your computer hasn't loaded it (after a restart or a new Terminal). Run: `ssh-add --apple-use-keychain ~/.ssh/hass_deploy` (Windows: see step 1) and try again. |
| `Host key unknown or changed` | See [docs/technical.md](docs/technical.md). |
| `Port 22 not reachable` | Is the SSH add-on running? Are you at home or on VPN? |
| `not writable` | The username in the SSH add-on must be `root` (not `hassio`). |
| `No YAML validator` | Mac: `pip3 install pyyaml`. Windows (Ubuntu): `sudo apt install python3-yaml` |
| Change not visible | Refresh with Cmd+Shift+R (Windows: Ctrl+Shift+R). |
| `git push` rejected | Run `git pull --rebase`, then `git push`. |

## License

[MIT](LICENSE)
