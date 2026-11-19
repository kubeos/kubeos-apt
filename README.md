# kubeos-apt

Publishing tooling for the KubeOS package archive served at <https://repo.kubeos.in/>.
Nothing here runs on a node: it builds a `.deb` and publishes it into the archive.

| Path | What |
|---|---|
| `bin/archive-publish.sh` | add one built `.deb` to the signed archive: pool → index → signature, in that order |
| `bin/build-deb.sh` | one fixed, predictable `dpkg-buildpackage` invocation |

## Archive layout

```
repo.kubeos.in/
├── kubeos-archive-keyring.asc
├── dists/trixie/{Release, Release.gpg, InRelease}
│              └── main/binary-amd64/{Packages, Packages.gz}
└── pool/main/k/kubeos-cli/kubeos-cli_1.0.0-1kubeos1_amd64.deb
```

A node enables it with one line, shipped by `kubeos-base`:

```
deb [signed-by=/etc/apt/keyrings/kubeos-archive-keyring.asc] https://repo.kubeos.in trixie main
```

## Publishing

```sh
export KUBEOS_ARCHIVE_REMOTE='r2:kubeos-repo'   # rclone remote:path of the bucket
export KUBEOS_GPG_KEY='KubeOS archive signing key'
bin/build-deb.sh                                 # inside a package repo
bin/archive-publish.sh ../kubeos-branding_0.1.0-1kubeos1_all.deb
```

`~/.config/rclone/rclone.conf` needs one section (chmod 600, written once, never committed):

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <never commit this>
secret_access_key = <never commit this>
endpoint = https://<account>.r2.cloudflarestorage.com
no_check_bucket = true
```

Set `KUBEOS_PUBLISH_DRY_RUN=1` to see exactly what would be uploaded.

## What the publisher guarantees

- **Order**: deb, then `Packages`, `Packages.gz`, `Release`, `Release.gpg`, `InRelease` — no
  client ever reads an index naming a file that is not there yet.
- **Cache**: index files are `no-cache`, pool files are `immutable` (a `.deb` path never
  changes content).
- **Idempotence**: publishing the same version again replaces its stanza instead of
  duplicating it.
- **Refusal**: it publishes only `kubeos-*` packages of the one architecture it is told to.
- **Proof**: after uploading, it re-reads `InRelease` and verifies the signature against the
  local keyring, so a broken publish fails loudly instead of silently.

## Still to come

- `action/publish/action.yml`, the composite action the package repos call from CI (needs the
  R2 + GPG secrets wired first).
- The archive signing key: generated once, private half only in GitHub secrets, backup
  offline; public half published here and shipped inside the ISO.
