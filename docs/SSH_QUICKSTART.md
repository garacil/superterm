# SuperTerm over SSH: AI deployment quickstart

This short guide publishes SuperTerm on a separate TCP port by using the
system's OpenSSH server. SuperTerm's dedicated setup leaves an already
installed ordinary SSH service and `/etc/ssh/sshd_config` unchanged. The
complete security and operational reference is
[SSH_SERVER.md](SSH_SERVER.md).

The procedure is deliberately deterministic so that either a human or an AI
operator can install the service, prove that it works from another machine,
and produce an auditable handoff. The example below uses:

- server address: `192.168.0.214`;
- dedicated SuperTerm port: `8022`;
- system account: `german`.

Replace those values with the address, port, and existing account for your
server.

## Required inputs

An automated operator must know these values before changing the server:

| Input | Example | Requirement |
|---|---|---|
| Server address | `192.168.0.214` | An address currently owned by the server |
| TCP port | `8022` | Free on that address and permitted by the intended network policy |
| Login account | `german` | Existing NSS account with a functional login shell that accepts `-c` |
| Authentication | Managed public key | Public key path and independently recorded SHA-256 fingerprint |
| Exposure | LAN interface or explicitly approved wildcard | Never assume Internet exposure |
| Client network | `192.168.0.0/24` | Approved source network or exact client address |
| Remote test host | `192.168.0.32` | A separate reachable machine with a standard SSH client |
| Firewall decision | No change, or an approved platform-specific rule | The operator must know which before setup |

If any value is unknown, stop and ask. Do not guess an interface, open a
wildcard listener, create a system account, change a firewall, or enable root
access without explicit authorization.

## Safety contract for an AI or automated operator

The operator must follow these rules:

1. Read the existing state before changing it. `setup` preserves an existing
   `server.ini`, host key, and managed keys; do not replace them with a sample.
2. Never edit `/etc/ssh/sshd_config`, stop the ordinary SSH service, or remove
   port 22 access. SuperTerm owns a separate listener and configuration.
3. Never copy, display, log, or upload a private key. `authorize` accepts a
   file containing exactly one unadorned OpenSSH public key; `.pub` is only
   the conventional suffix.
4. Bind only an explicitly approved server address. Leave firewall policy
   unchanged unless changing it is separately authorized.
5. Every command and expected-state check below must succeed. On any
   unexpected output or nonzero result, stop and report it; never continue
   from a partially understood state.
6. Run `check` before `restart`. If restart fails, verify the prior service
   and listener state. Report `rollback failed` as a critical failure; never
   claim that the old service was preserved without verifying it.
7. Test from a different client machine. A local socket/listener check alone
   does not prove routing, firewall, host-key verification, or authentication.
8. Keep the ordinary administrative connection open until the new connection
   has succeeded. Do not lock out the operator who is performing the setup.
9. Do not report completion until every item in the final checklist passes.

This quickstart is deliberately for a **new GNU/Linux x86_64 installation
with systemd**. If `/etc/superterm/sshd` already exists, stop: this is an
upgrade or recovery, and the retained policy must be audited with
[SSH_SERVER.md](SSH_SERVER.md) before running `setup`.

The commands below intentionally avoid rewriting generated files or hiding
errors. `sshd_config.generated` is owned by SuperTerm and must never be edited
manually.

## Read-only preflight

Before installing or running `setup`, verify the account, address, service
manager, existing state, and port:

```sh
test -d /run/systemd/system
sudo test ! -e /etc/ssh/sshrc
sudo test ! -e /etc/superterm/sshd
getent passwd german
ip -brief address
sudo ss -H -ltn 'sport = :8022'
```

Interpret the output instead of merely recording exit status:

- systemd must be the running service manager, and `/etc/ssh/sshrc` must not
  exist because OpenSSH would execute that global hook before `ForceCommand`;
- `/etc/superterm/sshd` must not exist for this clean-install procedure;
- `getent` must show the intended account and a real login shell which accepts
  `-c`; reject `nologin`, `false`, missing, or non-executable shells;
- `192.168.0.214` must appear on one of the server's interfaces;
- the `ss` command must print nothing. It checks port `8022` across exact,
  wildcard, loopback, IPv4, and IPv6 listeners, not only the desired address.

If the platform does not provide `getent`, `ip`, or `ss`, use its native
read-only account, interface, and listener inspection tools. Do not install a
replacement utility merely to make these examples run.

## 1. Install the prerequisites

The 4.2.1 GNU/Linux packages are for `x86_64`. Confirm the architecture and
identify the distribution without changing it:

```sh
uname -m
sed -n '1,80p' /etc/os-release
```

Stop if `uname -m` is not `x86_64`; do not install a package for the wrong
architecture. Download the package **and its matching `.sha256` file** from
the [v4.2.1 release](https://github.com/garacil/superterm/releases/tag/v4.2.1)
into a new temporary directory. Use exactly one of these package pairs:

| Distribution family | Package | Checksum file |
|---|---|---|
| Debian/Ubuntu | `superterm_4.2.1_amd64.deb` | `superterm_4.2.1_amd64.deb.sha256` |
| Fedora/RHEL | `superterm-4.2.1-1.x86_64.rpm` | `superterm-4.2.1-1.x86_64.rpm.sha256` |
| Arch Linux | `superterm-4.2.1-1-x86_64.pkg.tar.zst` | `superterm-4.2.1-1-x86_64.pkg.tar.zst.sha256` |

For example, the Debian/Ubuntu download and mandatory integrity check are:

```sh
ST_INSTALL_DIR="$(mktemp -d /tmp/superterm-4.2.1-install.XXXXXX)"
cd "$ST_INSTALL_DIR"
curl -fLO https://github.com/garacil/superterm/releases/download/v4.2.1/superterm_4.2.1_amd64.deb
curl -fLO https://github.com/garacil/superterm/releases/download/v4.2.1/superterm_4.2.1_amd64.deb.sha256
sha256sum -c superterm_4.2.1_amd64.deb.sha256
```

For RPM or Arch, download the two exact filenames from the table and run
`sha256sum -c CHECKSUM_FILE` in the same directory. Stop immediately if the
checksum does not report `OK`.

Install the verified package with the host's native package manager. Install
OpenSSH first only when `sshd` is missing and that system-package change was
explicitly approved; installing it may initialize the host's ordinary SSH
service:

```sh
# Debian or Ubuntu
sudo apt-get update
sudo apt-get install -y openssh-server
sudo apt-get install -y ./superterm_4.2.1_amd64.deb

# Fedora or RHEL (run this pair instead)
sudo dnf install -y openssh-server
sudo dnf install -y ./superterm-4.2.1-1.x86_64.rpm

# Arch Linux (run this pair instead)
sudo pacman -S --needed openssh
sudo pacman -U ./superterm-4.2.1-1-x86_64.pkg.tar.zst
```

Run only the block matching `/etc/os-release`. On another package family,
stop and use its reviewed package procedure; do not guess a command. The
portable tarball is not used here because this privileged service requires a
protected system installation, not an executable left in a download tree.

Verify the installed program before continuing:

```sh
command -v superterm
superterm --version
```

The version must be `4.2.1`, and the executable must be in a protected,
root-owned system path.

Do not configure the privileged service from a user-owned source checkout:
SuperTerm deliberately rejects an executable or ancestor directory writable
by an unprivileged user.

Before changing SuperTerm state, record the hash and metadata of an existing
`/etc/ssh/sshd_config`, the ordinary SSH listener, and the active
administrative connection. Compare them again at the end.

## 2. Create the dedicated service

Run this on the server:

```sh
sudo superterm ssh-server setup
```

On the clean state required by this guide, this creates the host key and
configuration below `/etc/superterm/sshd`, installs the separate systemd unit
at `/etc/systemd/system/superterm-sshd.service`, and enables and starts that
dedicated service. It does not replace, reconfigure, or restart the ordinary
host `sshd`. A newly created `server.ini` listens only on loopback. Never make
that claim for an existing retained configuration. If `setup` fails, report
an incomplete installation and preserve its diagnostic state; do not delete
the newly created identity or configuration automatically.

Immediately inspect the retained or newly created public state:

```sh
sudo sed -n '1,120p' /etc/superterm/sshd/server.ini
sudo ssh-keygen -l -E sha256 -f /etc/superterm/sshd/ssh_host_ed25519_key.pub
```

Record the host-key fingerprint for the remote verification step. Do not read
or print the private file `ssh_host_ed25519_key`.

## 3. Publish the LAN address

Edit the public configuration:

```sh
sudoedit /etc/superterm/sshd/server.ini
```

For the example server, use:

```ini
[server]
config_version=1
listen=192.168.0.214:8022
allow_root=0
password_authentication=0
managed_authorized_keys=1
user_authorized_keys=0
```

Use an address actually owned by the server. `0.0.0.0:8022` listens on every
IPv4 interface and `[::]:8022` on every IPv6 interface; choose either only
when that exposure is intentional. Do not proceed unless existing firewall
policy permits the approved client network or a separately authorized rule
has been applied through the host's reviewed firewall procedure.

## 4. Authorize exactly one client key

On the client, record the approved public-key fingerprint with
`ssh-keygen -l -E sha256 -f PUBLIC_KEY`. Transfer only that public key through the
existing administration path. On the server, calculate the staged file's
fingerprint and require an exact match before authorization:

```sh
ssh-keygen -l -E sha256 -f /path/to/german_ed25519.pub
```

The file must contain exactly one public key without `authorized_keys`
options. Its filename need not end in `.pub`. After the fingerprints match:

```sh
sudo superterm ssh-server authorize german /path/to/german_ed25519.pub
sudo superterm ssh-server list-keys german
```

The matching private key always remains on the client. Never copy it into
`/etc/superterm/sshd` or pass it to `authorize`.

The recommended `0/1/0` authentication policy admits only accounts with a
key in SuperTerm's managed store. Enabling password authentication or the
user's normal `authorized_keys` is **not** an allow-list for `german`: every
eligible non-root NSS account may then authenticate under the same policy.
Use those modes only after approving that wider account scope.

## 5. Validate and activate

Validate pending configuration before publishing it, restart only the
dedicated listener, and confirm its state:

```sh
sudo superterm ssh-server check
sudo superterm ssh-server restart
sudo superterm ssh-server status
```

If `check` fails, correct the reported problem and run it again. An invalid
edit does not replace the last accepted configuration.

Re-run the listener inspection and confirm that the exact approved endpoint,
not an unexpected wildcard, is active:

```sh
sudo ss -ltnp
```

The listener must be the approved exact address and port. Reject an unexpected
`0.0.0.0`, `[::]`, loopback, or second listener. This guide never changes a
firewall: if the approved client CIDR is blocked, stop and obtain authorization
for the host's reviewed, platform-specific firewall procedure.

## 6. Connect from any standard SSH client

From another machine on the LAN:

```sh
ssh -p 8022 german@192.168.0.214
```

An interactive `ssh` already requests a PTY, so `-tt` is normally unnecessary.
With this guide's key-only policy, OpenSSH tries the client's usual identities
and never falls back to an account password. For a private key with a
nonstandard filename:

```sh
ssh -o IdentitiesOnly=yes \
  -i ~/.ssh/superterm_ed25519 \
  -p 8022 german@192.168.0.214
```

Do not accept an unverified first-use prompt in automation. First obtain the
server-side fingerprint through the existing administrative channel:

```sh
sudo ssh-keygen -l -E sha256 -f /etc/superterm/sshd/ssh_host_ed25519_key.pub
```

The dedicated service has its own host key, so its fingerprint is expected to
differ from the ordinary SSH service on port 22.

On the separate client, capture only the presented Ed25519 public host key,
print its fingerprint, and compare it byte-for-byte with the recorded server
fingerprint:

```sh
ST_KNOWN_HOSTS="$(mktemp /tmp/superterm-known-hosts.XXXXXX)"
chmod 600 "$ST_KNOWN_HOSTS"
ssh-keyscan -T 5 -t ed25519 -p 8022 192.168.0.214 > "$ST_KNOWN_HOSTS"
ssh-keygen -l -E sha256 -f "$ST_KNOWN_HOSTS"
```

Only after the fingerprints match, connect without a fallback password or an
unverified host key:

```sh
ssh -tt -o BatchMode=yes -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ST_KNOWN_HOSTS" \
  -i ~/.ssh/superterm_ed25519 -p 8022 german@192.168.0.214
```

Never use `StrictHostKeyChecking=no` to make this test pass.

## 7. Optional client shortcut

Append a new entry to the client's `~/.ssh/config`:

```sshconfig
Host superterm
    HostName 192.168.0.214
    Port 8022
    User german
    RequestTTY force
```

Then connect with:

```sh
ssh superterm
```

Add `IdentityFile ~/.ssh/superterm_ed25519` inside that entry only when the
key does not have one of OpenSSH's standard names.

## What happens to the session?

The first login creates or attaches to a SuperTerm session owned by the
authenticated account. Detaching, closing the terminal window, or losing the
network removes only that viewer; the panes and processes remain alive. The
next SSH connection receives the live desktop as it was left.

Use `Ctrl-Q d` or **Sessions -> Detach** to detach deliberately. Do not use
**Exit** when the intention is to keep the last-viewer session alive.

The per-user `[session]` settings in `~/.superterm/superterm.ini` select the
initial session and profile. By default, `ssh_session=last` returns to the
latest live session entered through SSH. See
[CONFIGURATION.md](CONFIGURATION.md#dedicated-incoming-ssh-routing-and-service)
for the `default_session`, `default_profile`, and `ssh_session` options.

## Quick diagnostics

On the server:

```sh
sudo superterm ssh-server check
sudo superterm ssh-server status
sudo superterm ssh-server list-keys german
```

From the client:

```sh
ssh -vv -p 8022 german@192.168.0.214
```

Common interpretations:

- `Connection refused`: verify `status`, `listen`, and the firewall.
- `Permission denied (publickey)`: compare the offered key fingerprint with
  `list-keys` or the user's regular `authorized_keys`.
- A password prompt despite having a key: none of the offered public keys was
  accepted; `ssh -vv` shows which identities were tried.
- `interactive SSH PTY is required`: connect interactively or force a PTY with
  `-tt` from a non-terminal caller.

On GNU/Linux, the dedicated service log is available with:

```sh
sudo journalctl -u superterm-sshd.service -b
```

Keep the ordinary SSH service available until the dedicated connection has
been tested from another terminal. To stop only the SuperTerm listener while
preserving its configuration and keys:

```sh
sudo superterm ssh-server disable
```

For root access, Internet exposure, authentication policy details, upgrades,
rollback behavior, and the full troubleshooting table, read
[SSH_SERVER.md](SSH_SERVER.md).

## Required completion report

An AI operator must return a short report containing all of the following:

- installed SuperTerm version and executable path;
- configured server address and TCP port;
- login account and enabled authentication source, without credentials;
- dedicated host-key fingerprint;
- successful `ssh-server check` result;
- successful `ssh-server status` result;
- observed listener address (distinguish an exact address from a wildcard);
- result of a real `ssh -p PORT USER@SERVER` login from another machine;
- confirmation that detach followed by reconnect returns to the live session;
- whether a firewall rule was required and, if so, who authorized it;
- confirmation that the ordinary SSH service and `/etc/ssh/sshd_config` were
  not modified, based on the before/after metadata, hash, and listener
  baseline.

Any skipped or failed item must be reported as incomplete, not converted into
a successful installation claim.
