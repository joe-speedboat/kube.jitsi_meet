# Jitsi Meet on single-node k3s

This repository contains a small helper for running [Jitsi Meet](https://jitsi.org/jitsi-meet/) on a single-node k3s cluster with the `jitsi-contrib/jitsi-helm` chart.

The current helper targets:

- Kubernetes: single-node k3s
- OS: Rocky Linux 10 or another Linux host suitable for k3s
- Chart: `jitsi/jitsi-meet`, pinned by default to tested version `2.16.0`
- Ingress: Traefik or another standard Kubernetes Ingress controller
- Recording: Jibri, enabled through the Helm chart
- Authentication: internal Prosody users for moderators

The old manual files are kept under [`archive/`](archive/) for reference.

## What the helper does

`jitsi-recording-admin.sh` manages the deployment files and common operations:

- asks for the Jitsi FQDN during setup
- detects the node's WAN IP for the JVB public address
- generates a private Helm values file with Jibri passwords
- generates an Ingress manifest for the selected FQDN
- creates a `ReadWriteOnce` Jibri recording PVC for k3s `local-path`
- deploys/upgrades the Helm release
- manages moderator accounts in Prosody
- shows Jibri health, pod status, PVC status, and logs

## Why the recording PVC is handled manually

The `jitsi-meet` Helm chart version `2.16.0` generates the Jibri PVC with both `ReadWriteOnce` and `ReadWriteMany` access modes. The k3s `local-path` provisioner supports `ReadWriteOnce`, but not `ReadWriteMany`, so that generated PVC remains `Pending` on a normal single-node k3s setup.

The helper avoids that by creating this PVC itself:

```text
meet-jitsi-meet-jibri-rwo
```

It then points Jibri to that PVC through `jibri.persistence.existingClaim`.

## Prerequisites

On the k3s node or management host:

- `kubectl`
- `helm`
- `curl`
- access to the target k3s cluster
- a DNS record for the Jitsi FQDN pointing to the node's public IP
- open firewall ports:
  - `443/tcp` for HTTPS through the Ingress controller
  - `10000/udp` for Jitsi Videobridge media traffic

Add the Helm repository once:

```bash
helm repo add jitsi https://jitsi-contrib.github.io/jitsi-helm/
helm repo update jitsi
```

## Fresh setup

Run the interactive setup:

```bash
./jitsi-recording-admin.sh setup
```

It asks for:

- Kubernetes namespace, default: `meet`
- Helm release name, default: `meet`
- Jitsi FQDN, for example: `meet.example.ch`
- JVB WAN/public IP, auto-detected through HTTPS IP lookup and confirmable before writing files

Generated files:

- `.jitsi-recording.env` — internal Jibri passwords, mode `0600`, do not commit
- `my_values.yml` — generated Helm values, contains internal passwords, do not commit
- `my_ingress.yml` — generated Ingress manifest, safe to inspect before applying

The generated private files are ignored by `.gitignore`.

## Deploy

By default the helper installs the tested chart version `2.16.0` for reproducibility. This is intentional: a hidden floating chart can change values, templates, storage behavior, or authentication defaults and break a repeat deployment.

To explicitly use the newest chart available from the configured Helm repo, run deploy with `CHART_VERSION=latest`. Helm itself does not use a special `latest` chart version; the helper treats `latest` as "omit `--version`", which makes Helm install the newest chart from the repo index at that time.

Recommended flow for future upgrades:

```bash
helm repo update jitsi
helm search repo jitsi/jitsi-meet --versions | head
CHART_VERSION=latest ./jitsi-recording-admin.sh deploy
```

For production, prefer testing the newer chart first and then pinning the exact working version, for example:

```bash
CHART_VERSION=2.17.0 ./jitsi-recording-admin.sh deploy
```

For a fresh deployment where no existing data must be kept:

```bash
./jitsi-recording-admin.sh reset-deploy
kubectl apply -f my_ingress.yml
```

For an upgrade or repeat deployment without deleting existing PVCs:

```bash
./jitsi-recording-admin.sh deploy
kubectl apply -f my_ingress.yml
```

Check the result:

```bash
./jitsi-recording-admin.sh status
kubectl get pods -n meet
kubectl get pvc -n meet
```

Expected important PVCs:

```text
meet-jitsi-meet-jibri-rwo                  Bound
prosody-data-meet-jitsi-meet-prosody-0     Bound
```

## Add a moderator

With internal authentication enabled, only registered users can create moderated rooms and start recording.

Add a moderator interactively:

```bash
./jitsi-recording-admin.sh moderator add chris
```

List moderators:

```bash
./jitsi-recording-admin.sh moderator list
```

Change a password:

```bash
./jitsi-recording-admin.sh moderator passwd chris
```

Delete a moderator:

```bash
./jitsi-recording-admin.sh moderator delete chris
```

The moderator commands also accept a full JID when you intentionally need a non-default domain:

```bash
./jitsi-recording-admin.sh moderator passwd chris@meet.jitsi
```

## Recording checks

Check Jibri health:

```bash
./jitsi-recording-admin.sh jibri-health
```

Follow Jibri logs:

```bash
./jitsi-recording-admin.sh logs-jibri
```

After a test recording, check the Jibri recording volume on the node or through a debug pod, depending on how the k3s `local-path` volume was provisioned.

## Useful environment overrides

All defaults can be overridden through environment variables:

```bash
NAMESPACE=meet \
RELEASE=meet \
PUBLIC_URL=https://meet.example.ch \
JVB_PUBLIC_IP=203.0.113.10 \
./jitsi-recording-admin.sh render-values
```

Common overrides:

- `NAMESPACE` — Kubernetes namespace, default: `meet`
- `RELEASE` — Helm release name, default: `meet`
- `CHART_VERSION` — Helm chart version, default: tested pin `2.16.0`; set to `latest` to omit `--version` and let Helm use the newest repo version
- `PUBLIC_URL` — external URL, for example `https://meet.example.ch`
- `JVB_PUBLIC_IP` — public IP advertised by JVB
- `VALUES_FILE` — generated values file, default: `my_values.yml`
- `INGRESS_FILE` — generated ingress file, default: `my_ingress.yml`
- `JIBRI_PVC_SIZE` — recording PVC size, default: `32Gi`
- `JIBRI_STORAGE_CLASS` — storage class, default: `local-path`

## Notes

- Keep `.jitsi-recording.env` and `my_values.yml` private. They contain internal service passwords.
- The helper redacts Jibri passwords from `status` output.
- Human moderator accounts are registered in the normal Jitsi XMPP domain, usually `meet.jitsi`. The internal `auth.meet.jitsi` domain is for system components.
- This repository keeps the original manual README, values, and ingress templates in `archive/` only for reference.
