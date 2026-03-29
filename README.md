# openhabUpdater

Automated zero-downtime updater for [OpenHAB](https://www.openhab.org/) running in Docker, using a **blue-green deployment** strategy.

## How It Works

Two containers (`openhab-hera` and `openhab-zeus`) take turns being active. On each run the script:

1. Pulls the latest `openhab/openhab` Docker image.
2. Backs up the active container's data directory.
3. **If a new version is available:**
   - Syncs the active container's data to the dormant slot.
   - Starts the dormant container with the new image.
   - Runs a health-check (`check_oh.sh`); if it passes, promotes the new container to active.
   - On failure, automatically rolls back to the previous container.
4. **If no new version is available:** simply restarts the active container (e.g. after a backup window).

Telegram notifications are sent at every significant step.

## Requirements

| Tool | Purpose |
|------|---------|
| `bash` ≥ 4 | Script runtime |
| `docker` | Container management |
| `jq` | Parse Docker image labels |
| `zip` | Create backups |
| `rsync` | Sync data between slots |
| `curl` | Health checks & Telegram API |

## Directory Layout

```
/volume1/docker/openhab/
├── general/              # Clone this repository here
│   ├── update.sh
│   ├── check_oh.sh
│   ├── lib_common.sh
│   ├── .env              # Your secrets (not committed)
│   └── active_container  # Runtime state: "hera" or "zeus"
├── hera/                 # Data dir for container openhab-hera
│   ├── addons/
│   ├── conf/
│   └── userdata/
├── zeus/                 # Data dir for container openhab-zeus
│   ├── addons/
│   ├── conf/
│   └── userdata/
└── backups/              # Created automatically; zip archives land here
```

## Setup

### 1. Clone the repository

```bash
git clone https://github.com/johannesz-codes/openhabUpdater.git \
    /volume1/docker/openhab/general
cd /volume1/docker/openhab/general
```

### 2. Create your `.env`

```bash
cp .env.example .env
chmod 600 .env        # Restrict access – contains bot token
```

Edit `.env` and fill in the values described in `.env.example`.

### 3. Create the data and backup directories

```bash
mkdir -p /volume1/docker/openhab/{hera,zeus}/{addons,conf,userdata}
mkdir -p /volume1/docker/openhab/backups
```

### 4. Initialise the state file

```bash
echo "hera" > /volume1/docker/openhab/general/active_container
```

### 5. Start your initial OpenHAB container

```bash
docker run -d \
  --name openhab-hera \
  --network macvlan --ip 192.168.11.10 \
  --restart=always \
  -e USER_ID=9999 -e GROUP_ID=999 \
  -e TZ=Europe/Berlin \
  -e OPENHAB_HTTP_PORT=8080 \
  -e OPENHAB_HTTPS_PORT=8443 \
  -v /volume1/docker/openhab/hera/addons:/openhab/addons \
  -v /volume1/docker/openhab/hera/conf:/openhab/conf \
  -v /volume1/docker/openhab/hera/userdata:/openhab/userdata \
  openhab/openhab:latest
```

### 6. Make the scripts executable

```bash
chmod +x update.sh check_oh.sh
```

### 7. Schedule the updater (cron example)

```cron
# Run every Sunday at 03:00
0 3 * * 0 /volume1/docker/openhab/general/update.sh >> /var/log/openhab-updater.log 2>&1
```

## Configuration

All settings have sensible defaults but can be overridden via `.env` or environment variables.

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENHAB_IP` | `192.168.11.10` | IP assigned to the macvlan interface |
| `OPENHAB_HTTP_PORT` | `8080` | OpenHAB HTTP port |
| `OPENHAB_HTTPS_PORT` | `8443` | OpenHAB HTTPS port |
| `WORK_DIR` | `/volume1/docker/openhab/general` | Directory containing `update.sh` |
| `OH_DATA_ROOT` | `/volume1/docker/openhab` | Parent directory of `hera/`, `zeus/`, `backups/` |
| `OH_USER_ID` | `9999` | UID for the OpenHAB process |
| `OH_GROUP_ID` | `999` | GID for the OpenHAB process |
| `TZ` | `Europe/Berlin` | Container timezone |
| `bot_token` | *(none)* | Telegram bot token (required for notifications) |
| `chat_id` | *(none)* | Telegram chat/group ID (required for notifications) |

## Health Check Script

`check_oh.sh` can be used independently:

```bash
./check_oh.sh <IP> [port]
# Example:
./check_oh.sh 192.168.11.10 8080
```

Exit codes:

| Code | Meaning |
|------|---------|
| `0` | OpenHAB is reachable and the `challenge` item returned `pass` |
| `1` | Health check failed (unreachable or wrong state) |
| `2` | Invalid arguments |

The script sends a `challenge` command to the `challenge` OpenHAB item and polls its state for up to 60 seconds.

## Rollback Behaviour

If the new container fails its health check, `update.sh` will:

1. Stop the new (failed) container.
2. Restart the previous container.
3. Run the health check again; send a success or failure notification via Telegram.
4. Exit with code `1` to signal the failed update.

The `active_container` state file is updated **atomically** (write to `.tmp`, then `mv`) so it is never left in a partial state.

## Security Notes

- `.env` is listed in `.gitignore` — **never commit it**.
- Restrict permissions: `chmod 600 .env`.
- The health check uses plain HTTP because OpenHAB's internal REST API is typically on a private LAN. If your setup exposes the API externally, configure HTTPS and pass `--cacert` to the `curl` calls in `check_oh.sh`.

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
