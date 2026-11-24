# sak — Swiss Army Knife: CMS & cPanel Operations Toolkit (`v2.0.0`)

A modern, standalone Bash + Python 3 CLI toolkit for **CMS discovery, WordPress diagnostics, permission auditing/hardening, `chmod 600` SHA-256 backups, and Linux/cPanel user inspection** — replacing the legacy 2013 Bash `sak` (`0.1.5`) with clean subcommands and `table` / `json` / `csv` outputs.

## Historical Modernization

Inspired by the original **Swiss Army Knife (`sak` v0.1.5, `20130930.A`)** authored by **Jon South (`jsouth@hostgator.com`, HostGator.com)**.

In `v2.0.0`, the 2,153-line legacy Bash script was rebuilt cleanly in **Bash + Python 3.6+ (stdlib)** to eliminate obsolete dependencies and limitations:
- **Removed Dead Dependencies**: Eliminated remote `vdetect` downloads from `git.toolbox.hostgator.com`, `LWP GET`, `dialog`/curses UI loops, and `projects.hostgator.com` links.
- **Lifted Legacy Constraints**: Removed the hardcoded `UID >= 500` and `username <= 8 characters` limits when resolving Linux/cPanel accounts.
- **Security Hardening**: Replaced plain backups and CLI MySQL flags with `chmod 600` tarballs + SHA-256 manifests, path-traversal-safe extraction (`restore`), and `--defaults-extra-file` (`chmod 600`) DB checks.

## Subcommands

| Subcommand | Description |
| :--- | :--- |
| `scan` | Offline CMS & web app detection (WordPress, Joomla, Drupal, Laravel, Next.js) |
| `wp-info` | Parse `wp-config.php`, count plugins/themes, and test DB login (`--check-db`) |
| `perms` | Audit or `--fix` directory/file permissions (`755` / `644` / `600` for secrets) |
| `backup` | Create `chmod 600` `.tar.gz` backup with `.json` SHA-256 manifest |
| `restore` | Safely extract `.tar.gz` archive with path-traversal validation |
| `users` | List Linux/cPanel users and reseller mappings (`/etc/trueuserowners`) |

## Real Output Example

```text
$ ./sak.sh scan -p /tmp/sak-e2e/site --no-color
=== sak.sh v2.0.0 | scan ===
APPLICATION  VERSION  PATH
---------------------------------------------
WordPress    6.6.1    /tmp/sak-e2e/site
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
