# hetzner-cx23-watch

**Get a push on your phone the moment a sold-out Hetzner Cloud server type is back in stock, and
optionally let it create the server for you.**

[Leia em português](README.pt-BR.md)

## Why

Since mid-2026 Hetzner's cheap Cost-Optimized line (CX23 and friends) shows as "temporarily not
available" most of the time. It is not really gone: community trackers show stock coming back
**several times a day, in every EU location, and selling out again within minutes**. Refreshing the
Console does not work, and by the time an email alert is read the window is usually closed.

This repository is a tiny watcher that runs for free on GitHub Actions:

- checks the Hetzner Cloud API every 5 minutes (`server_types[].locations[].available`);
- sends a push notification through [ntfy](https://ntfy.sh) when availability changes;
- **optionally creates the server** in the first window, in your preferred locations, with your SSH
  key, firewall, image, labels and backups, then disables itself.

No server, no dependencies: one shell script (`curl` + `jq`) and one workflow.

## Setup (about 5 minutes)

1. **Create your own copy:** click **Use this template** → *Create a new repository*. Make it
   **public** if you want unlimited free Actions minutes (every 5 minutes is ~8,600 runs a month,
   more than the 2,000 free minutes of a private repo). Secrets stay secret in a public repository;
   see [Security](#security).
2. **Hetzner API token:** Hetzner Console → your project → *Security* → *API tokens* → *Generate*.
   Permission **Read** to only watch, **Read & Write** to auto-create.
3. **ntfy:** install the ntfy app (Android or iOS) and subscribe to a hard-to-guess topic (anyone who
   knows the name can read it), e.g. `echo cx23-$(openssl rand -hex 12)`.
4. **Secrets** (*Settings → Secrets and variables → Actions → Secrets*), or with the GitHub CLI:

   ```
   gh secret set HCLOUD_TOKEN -R <you>/<repo>
   gh secret set NTFY_TOPIC  -R <you>/<repo>
   ```

5. **Variables** (*Settings → Secrets and variables → Actions → Variables*), all optional for
   watching only:

   | Variable | Default | Meaning |
   | --- | --- | --- |
   | `SERVER_TYPE` | `cx23` | Server type to watch |
   | `LANGUAGE` | `en` | `en` or `pt-BR`, for logs and notifications |
   | `CREATE` | `false` | `true` creates the server in the first window |
   | `LOCATIONS` | — | Locations accepted for creation, in order of preference, e.g. `hel1,nbg1` |
   | `SERVER_NAME` | — | Name of the server (required to create) |
   | `SSH_KEY` | — | Name of an SSH key already in the project (required to create) |
   | `FIREWALL` | — | Name of a firewall in the project to attach (optional) |
   | `IMAGE` | `ubuntu-24.04` | System image |
   | `BACKUPS` | `true` | Enable Hetzner backups (+20% of the price) |
   | `LABELS` | `created-by=hetzner-cx23-watch` | Server labels, `key=value,key=value` |

6. **Test it** from the *Actions* tab (*Hetzner stock watch* → *Run workflow*) or:

   ```
   # a test push should arrive within a minute
   gh workflow run watch.yml -R <you>/<repo> -f test_notification=true

   # checks SSH key, firewall, image and write permission, without creating anything
   gh workflow run watch.yml -R <you>/<repo> -f test_creation=true
   ```

Set `CREATE` to `true` only after `test_creation` reports "Ready to create".

## How it behaves

- **Quiet unless something changes.** One push when the type shows up (with the locations), one
  low-priority push when it sells out again. The last seen state lives in `state.txt`, and its
  commit history doubles as an availability log.
- **Never creates two servers.** Before creating it checks whether a server with `SERVER_NAME`
  already exists.
- **A closed window is not an error.** If stock runs out between the check and the create request
  (`resource_unavailable`), it waits for the next window.
- **Stops by itself.** After creating the server (or finding it already there) it sends a push and
  disables the workflow.
- **Creating costs money from that moment on**, at the normal Hetzner price.

## Security

- **Secrets are not readable**, not even by you; GitHub masks them as `***` in logs.
- **Forks never get your secrets.** The workflow only runs on schedule or by manual dispatch from
  someone with write access; there is no pull request trigger.
- **The log is public**, so the script never prints full API responses nor the server's IP address.
  Repository variables are not secret and do show up in the log.
- **One third-party action**, `actions/checkout`, pinned by commit SHA.
- **A Read & Write token can create and delete servers in its project.** Revoke it in the Hetzner
  Console as soon as the server is created; the "server created" push reminds you.

## Limits

- Hetzner calls `available` an indicator, not a guarantee.
- GitHub may delay scheduled runs by several minutes at busy times.
- GitHub disables scheduled workflows in public repositories after 60 days without activity.
- Not affiliated with Hetzner.

## License

[MIT](LICENSE)
