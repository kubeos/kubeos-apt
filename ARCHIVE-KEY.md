# The KubeOS archive signing key

| | |
|---|---|
| Fingerprint | `EFFD44EAF9257BD4FC6860B7931C72295B719DCE` |
| Key id | `931C72295B719DCE` |
| Type | RSA 4096, usage SC (certify + sign) |
| Created | 2026-11-19 |
| Expires | 2031-11-18 |
| UID | `KubeOS archive signing key <mail@kubeos.in>` |

`kubeos-archive-key.asc` in this directory is the **public** half. It is safe to publish and it
is meant to be published, in three places:

1. the archive root at <https://repo.kubeos.in/kubeos-archive-key.asc>,
2. `/etc/apt/keyrings/kubeos-archive-keyring.asc` on every node (shipped by `kubeos-base`),
3. the ISO build (`config/archives/kubeos.key.chroot` and `.binary`).

The **private** half and its passphrase are not in any repository. They are held on the build
machine and belong in GitHub Actions secrets (`GPG_PRIVATE_KEY`, `GPG_PASSPHRASE`); the
revocation certificate must be backed up offline, separately from the key.

## Rotating it

Ship the new public keyring in the next ISO, keep the old key valid until the last node built
with it has upgraded, then delete the old key from the archive's keyring package.
