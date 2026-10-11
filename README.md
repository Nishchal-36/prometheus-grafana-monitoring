# Prometheus + Grafana Monitoring Lab on Azure

A complete, Infrastructure-as-Code monitoring project:

- **2x Windows Server 2022 VMs** running an Nginx reverse proxy, a Node.js demo app with custom Prometheus instrumentation, `windows_exporter`, an Nginx exporter and Grafana Alloy — the **comparison pair**.
- **1x Ubuntu VM** running the full **Docker Compose monitoring stack**: Prometheus, Alertmanager, Grafana, Loki and Alloy.
- **Terraform** provisions everything (network, NSGs, VMs, provisioning hooks).
- **GitHub Actions** deploys config changes and lets you stop/start the VMs to save money.

Everything is provisioned from scratch — no manual clicking in the Azure portal.

## Architecture

```
                          Azure VNet 10.0.0.0/16 (centralindia)
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│  snet-web 10.0.1.0/24                        snet-monitoring 10.0.2.0/24    │
│  ┌──────────────────────────┐  ┌──────────────────────────┐  ┌───────────┐  │
│  │ win-web-1                │  │ win-web-2                │  │ mon-linux-1│ │
│  │  • Nginx :80 -> :3000    │  │  • Nginx :80 -> :3000    │  │           │ │
│  │  • Node demo app :3000   │  │  • Node demo app :3000   │  │ Docker:   │ │
│  │  • windows_exporter :9182│  │  • windows_exporter :9182│  │ Prometheus│ │
│  │  • nginx-exporter :9113  │  │  • nginx-exporter :9113  │  │ Alertmgr  │ │
│  │  • Alloy (logs)          │  │  • Alloy (logs)          │  │ Grafana   │ │
│  └───────────┬──────────────┘  └───────────┬──────────────┘  │ Loki      │ │
│              │         metrics scrape      │                 │ Alloy     │ │
│              └──────────────┬──────────────┘                 │ node_exp. │ │
│                             │                                └─────┬─────┘ │
│                             └──────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────────────┘
        ▲                              ▲
        │ 80 (demo)                    │ 3000 Grafana / 9090 Prometheus / 9093 Alertmanager
        │ 3389 RDP (your IP only)      │ 22 SSH (your IP only)
```

All VM access is restricted to your current public IP (auto-detected by Terraform).

## Stack versions

| Component | Version | Where |
|---|---|---|
| Prometheus | v3.15.0 | mon-linux-1 (Docker) |
| Grafana | 13.2.3 | mon-linux-1 (Docker) |
| Loki | 3.7.8 | mon-linux-1 (Docker) |
| Alertmanager | v0.34.1 | mon-linux-1 (Docker) |
| node_exporter | v1.12.1 | mon-linux-1 (Docker) |
| Alloy | v1.20.1 | all VMs (logs) |
| windows_exporter | 0.31.9 | win-web-1/2 |
| nginx-prometheus-exporter | 1.5.3 | win-web-1/2 |
| Nginx for Windows | 1.30.5 | win-web-1/2 |
| Node.js | 24 LTS | win-web-1/2 |

## Repository layout

```
terraform/            Azure infrastructure (VMs, network, cloud-init, credentials)
scripts/              windows-setup.ps1 (provisioning) + cost control scripts
app/                  Node.js demo app with prom-client custom metrics
windows/              Nginx config + Alloy config for the Windows VMs
monitoring/
  docker-compose.yml  Prometheus, Alertmanager, Grafana, Loki, Alloy, node_exporter
  prometheus/         scrape config, alert rules, recording rules
  alertmanager/       routing + notification config (email/Slack placeholders)
  grafana/            datasource + dashboard provisioning (4 dashboards)
  loki/, alloy/       log storage and collection configs
.github/workflows/    CI (terraform fmt/validate) + CD (deploy) + VM power control
```

## Prerequisites

- Azure CLI authenticated (`az login`) with a subscription that can create VMs
- Terraform >= 1.6
- GitHub CLI (`gh auth login`) — for the repo and Actions
- That's it. Docker is **not** needed locally.

## Deploy

```powershell
# 1. Push this repo to GitHub (or use the one you cloned)
gh auth login
gh repo create prometheus-grafana-monitoring --public --source . --push

# 2. Configure Terraform
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: set repo_raw_base and github_repo_url to YOUR repo

# 3. Deploy (~10 min; Windows VMs finish provisioning ~5 min after apply)
terraform init
terraform apply
```

Terraform prints everything you need at the end:

```
windows_public_ips     = ["20.x.x.x", "20.x.x.y"]
monitoring_public_ip   = "20.x.x.z"
grafana_url            = "http://20.x.x.z:3000"
prometheus_url         = "http://20.x.x.z:9090"
alertmanager_url       = "http://20.x.x.z:9093"
ssh_command            = "ssh -i monitoring_ssh_key.pem azureuser@20.x.x.z"
```

All credentials are also written to `terraform/.generated-credentials.txt` (gitignored) and the SSH key to `terraform/monitoring_ssh_key.pem`.

> **Note:** Windows VMs need a few minutes after `apply` to install Node, Nginx, exporters and Alloy (Azure Custom Script Extension). Watch it in the portal under the VM → Extensions, or RDP in and look at `C:\setup\setup.log`.

## Verify the pipeline

1. Open the demo app on either VM: `http://<windows_public_ip>/` → click **Run 1 slow job** / **Burn CPU 10s** a few times.
2. Open Prometheus targets: `http://<monitoring_ip>:9090/targets` → all jobs should be **UP** (windows, nginx, node-app, node-exporter, prometheus, alertmanager, loki).
3. Open Grafana: `http://<monitoring_ip>:3000` (admin / password from credentials file) → folder **Observability Lab**:
   - **Windows VMs - System Overview** — CPU/memory/disk/network per VM
   - **Windows VMs - Side-by-Side Comparison** — the two VMs overlaid + current bargauges
   - **Demo App - Custom Application Metrics** — request rate, p95 latency, jobs, error codes
   - **Monitoring Server - Linux Overview** — the monitoring VM itself
4. Generate load and watch the comparison dashboards diverge (load one VM only and compare).

## Alerting

Alert rules are defined in `monitoring/prometheus/alert.rules.yml` (instance down, high CPU/memory, low disk, app error rate, slow p95). They fire into Alertmanager, whose routing lives in `monitoring/alertmanager/alertmanager.yml`.

To actually receive notifications, edit `alertmanager.yml`, uncomment the email or Slack block and reload:

```bash
cd /opt/monitoring-repo && git pull
docker compose -f monitoring/docker-compose.yml restart alertmanager
```

## Logs (Loki + Alloy)

- The monitoring VM ships all container logs to Loki (Alloy + docker socket).
- The Windows VMs ship **Windows Event Logs (Application/System)** plus **Nginx access/error logs** to Loki.
- Correlate in Grafana → **Explore** → Loki datasource, filter by `{server="win-web-1"}` or `{job="nginx-access"}` next to a Prometheus metric panel — that is the advanced log/metric correlation goal.

## CI/CD setup (GitHub Actions)

The workflows need a few repository secrets:

```powershell
# Azure service principal for azure/login (used by redeploy + power control workflows)
az ad sp create-for-rbac --name monlab-github `
  --role Contributor `
  --scopes /subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-monlab-monitoring `
  --sdk-auth
# paste the JSON output into the AZURE_CREDENTIALS repo secret

# Monitoring VM SSH deploy
gh secret set MONITORING_HOST       # monitoring public IP
gh secret set MONITORING_USER      # azureuser
gh secret set MONITORING_SSH_KEY < terraform/monitoring_ssh_key.pem
```

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform.yml` | push/PR on `terraform/**` | `fmt -check`, `init -backend=false`, `validate` |
| `deploy-monitoring.yml` | push on `monitoring/**` | SSH → git pull → `docker compose up -d` → Prometheus reload |
| `redeploy-windows-app.yml` | manual | Updates the demo app on both Windows VMs via `az vm run-command` |
| `vm-power.yml` | manual | Deallocate/start all VMs (cost saver) |

## Cost control

Three `Standard_B2ms` VMs run for roughly **$10-12/day** if left on 24/7 (Windows licenses included). To save money:

```powershell
# Local
.\scripts\az-stop-all.ps1     # deallocate (stops compute billing, keeps disks)
.\scripts\az-start-all.ps1
```

Or use the **VM power control** GitHub Action. Deallocated VMs still cost their disks (~$5-10/month per VM).

## Troubleshooting

| Symptom | Check |
|---|---|
| Windows stack missing | RDP → `C:\setup\setup.log`, service status `Get-Service \| ? {$_.Name -match 'nginx\|node\|alloy\|windows'}` |
| Target DOWN in Prometheus | From mon VM: `curl http://<web_private_ip>:9182/metrics` (NSG allows 10.0.2.0/24; firewalls added by script) |
| Grafana empty panels | `http://<mon_ip>:9090/targets`, then run the panel query in Prometheus UI first |
| Loki empty | `docker compose logs alloy` on the mon VM; Alloy on Windows logs to `C:\setup\logs\alloy.err.log` |
| Nginx 502 | Node app down: `Restart-Service node-app` on the Windows VM |
| Prometheus config change | `curl -X POST http://localhost:9090/-/reload` on the mon VM |

## Advanced goals coverage

- [x] Alerting rules in Prometheus + Alertmanager channels
- [x] Prometheus recording rules (`recording.rules.yml`)
- [x] Service discovery (file_sd for the web tier — add a VM's IP to the JSON and it's monitored, no Prometheus restart; Azure SD in `prometheus.yml` comments is the natural next step)
- [x] Loki log aggregation + Grafana correlation (Alloy on all VMs)
- [x] Custom exporter/instrumentation — the Node.js app exposes custom counters/histograms (`/metrics`)

## Ideas to take it further

- Export the Grafana dashboards back into `monitoring/grafana/dashboards/` after UI edits (`allowUiUpdates: true` is on) and commit them.
- Move Terraform state to an Azure Storage backend for team use.
- Add `azure_sd_configs` to scrape any VM tagged `monitoring=true` automatically.
- Wire Alertmanager to a real Slack channel and demo an alert firing end-to-end.
