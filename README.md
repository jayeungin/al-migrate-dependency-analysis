# Amazon Linux to RHEL Migration Analyzer

A web-based tool that analyzes Amazon Linux instances and generates migration compatibility reports for Red Hat Enterprise Linux (RHEL). Upload a system inventory from an AL2 or AL2023 instance and get a detailed breakdown of package mappings, runtime availability, and migration risk.

## Supported Migration Paths

| Source | Target |
|---|---|
| Amazon Linux 2 | RHEL 8, RHEL 9 |
| Amazon Linux 2023 | RHEL 9, RHEL 10 |

## How It Works

1. **Discover** — Run `discover.sh` on your Amazon Linux instance to collect a full package and runtime inventory.
2. **Analyze** — Upload the inventory JSON to the web UI or POST it to the API.
3. **Review** — Get a color-coded report with package mapping status, runtime compatibility, running services, and network listeners.

### Risk Levels

- **Green** — Direct match, package exists in RHEL with the same name.
- **Yellow** — Package was renamed or replaced; migration path exists.
- **Red** — Package was removed or requires manual intervention.
- **Gray** — Unknown; not in the mapping database, needs manual review.

## Quickstart

### Run Locally

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python run.py
```

The app starts at `http://localhost:8000`.

Set `DEV=1` to enable auto-reload during development:

```bash
DEV=1 python run.py
```

### Run with Podman

```bash
podman build -t al-migrate-analyzer .
podman run -p 8000:8000 al-migrate-analyzer
```

## Discovery Script

Run `discover.sh` on the source Amazon Linux instance to generate the inventory JSON:

```bash
# Copy discover.sh to your AL instance, then:
chmod +x discovery/discover.sh
sudo ./discovery/discover.sh

# Output: inventory-<hostname>-<timestamp>.json
```

The script collects:
- OS version and architecture
- All installed RPM packages
- Enabled repositories
- Running and enabled services
- Runtime versions (Java, Python, Node.js, Ruby, Go, PHP, .NET, Perl)
- Language-specific packages (pip, npm globals, gems, PHP modules)
- Loaded kernel modules
- Network listeners

No external dependencies required. Root/sudo is recommended for full visibility.

## API

### `POST /api/analyze`

Accepts an inventory JSON file or raw JSON body. Returns a full migration report as JSON.

```bash
# Upload a file
curl -X POST -F "file=@inventory.json" -F "target_os=rhel9" \
     http://localhost:8000/api/analyze

# POST JSON body
curl -X POST -H "Content-Type: application/json" \
     -d @inventory.json \
     http://localhost:8000/api/analyze
```

The `target_os` field can be included in the form data or in the JSON body itself (`rhel8`, `rhel9`, or `rhel10`).

## Project Structure

```
├── app/
│   ├── main.py            # FastAPI routes (web UI + API)
│   ├── analyzer.py        # Analysis engine
│   ├── models.py          # Pydantic models (inventory, report)
│   ├── templates/         # Jinja2 HTML templates
│   └── static/            # CSS and JS
├── discovery/
│   └── discover.sh        # Inventory collection script for AL instances
├── mappings/
│   ├── runtimes.json      # Runtime availability by RHEL version
│   └── packages/          # Package mapping files (AL → RHEL)
├── samples/
│   └── sample-inventory-al2.json
├── Containerfile
├── requirements.txt
└── run.py
```
