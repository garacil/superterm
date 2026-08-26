# SuperTerm dedicated SSH server

SuperTerm can publish its interface over TCP by using the system's OpenSSH
`sshd`. OpenSSH handles encryption, account authentication, the PTY, and
terminal resizing; the process that it starts afterwards is the same
SuperTerm client used locally. That client connects to the session daemon
through its private Unix socket, so there is only one canonical desktop and
one session protocol.

It does not provide a conventional SSH *shell*: the instance can authenticate
with a password accepted by the `sshd` PAM policy or with public keys, but it
rejects remote commands, SFTP, forwarding, X11, SSH agent forwarding, and
sessions without a PTY. Once authenticated, the user can open panes and run
the commands allowed by their normal SuperTerm configuration; those processes
run under the UID of the authenticated account (including root only when it is
explicitly enabled). This instance can therefore replace **interactive** SSH
access on a compatible server, but it does not yet replace uses of `sshd` for
`scp`, SFTP, command automation, or tunnels. Nor is it a sandbox for programs
that the user starts inside SuperTerm.

Losing the connection closes only the client: the SuperTerm session remains
alive, and the next client receives it exactly as it was left.

This document is the reference for the complete integration: installation,
architecture, authentication, process lifecycle, sessions, operation,
diagnostics, and security limits. The configuration file to edit is always
`server.ini`; the other generated files are explained so that they can be
audited, not so that they can be edited manually.

## Immediate result: standard `ssh`, separate service

Once the listener has been prepared, a standard OpenSSH client enters
SuperTerm directly with a normal command:

```sh
ssh -p 8022 german@192.168.0.214
```

An interactive terminal does not require `-tt`: `ssh` already requests a PTY.
There is no need to specify `IdentityFile` either when the key is one of the
client's usual identities; if no key matches and password authentication has
been enabled, OpenSSH prompts for the password and PAM decides whether the
account may log in.

The host's regular `sshd` remains untouched and can continue listening on its
usual port. The separation is concrete and verifiable:

| Property | Host's regular SSH | SuperTerm dedicated SSH |
|---|---|---|
| Process and service | Existing SSH service | SuperTerm's own service |
| Addresses/ports | Those already configured, normally port 22 | Explicit `listen` list, for example port 8022 |
| Configuration and host keys | `/etc/ssh` | `/etc/superterm/sshd` |
| Resulting session | Normal shell, command, or subsystem | Forced SuperTerm interface |
| SCP/SFTP/tunnels | According to the regular policy | Deliberately rejected |

`setup`, `restart`, `disable`, and `uninstall-service` manage only the
dedicated instance: they do not write `/etc/ssh/sshd_config`, replace the
regular host keys, or stop or restart the normal service. Both instances reuse
the same installed OpenSSH binary, NSS accounts, and `sshd` PAM policy; the
dedicated instance can also optionally **read** each account's
`~/.ssh/authorized_keys`, but SuperTerm never modifies it. This reuse is
stated explicitly so that operational isolation is not mistaken for a second
account database or a second cryptographic implementation.

## Architecture: two transports, one session

OpenSSH and SuperTerm neither compete nor implement two terminal servers.
Each one handles a different boundary:

```text
client machine
  ssh(1) + graphical terminal
          |
          | encrypted, authenticated TCP with a PTY
          v
SuperTerm dedicated sshd (root, configured port)
          |
          | ForceCommand, now running as the authenticated account
          v
superterm --ssh-entry (UID german, root, or another account)
          |
          | private AF_UNIX: ~/.superterm/sessions/NAME.sock
          v
daemon for that SuperTerm session (same UID)
          |
          +-- PTY/pane 1 -> account process
          +-- PTY/pane 2 -> account process
          `-- canonical state -> all attached clients
```

There are two deliberately separate transport planes:

- The outer plane is SSH over TCP. OpenSSH implements key exchange,
  encryption, integrity, authentication, PAM, PTY allocation, keepalives,
  and `SIGWINCH` changes.
- The inner plane is SuperTerm's binary session protocol over a `0600` Unix
  socket. It is the same protocol used by a local client; it is never exposed
  directly over TCP or published to the LAN.

This separation leaves a single source of truth. The session daemon is the
sole owner of panes, PTYs, geometry, shared focus, and the desktop revision.
Each SSH entry is simply another viewer/controller of the same object. There
is no copy of the session inside `sshd`.

| Component | Runs as | Responsibility | Lifetime |
|---|---|---|---|
| Dedicated `sshd` | root while listening; OpenSSH drops privileges per connection | TCP, cryptography, authentication, PAM, and the outer PTY | System service |
| `superterm --ssh-entry` | authenticated user | Validate that this is an interactive entry, resolve the session, and attach to or create it | Lasts as long as the SSH client |
| SuperTerm session daemon | same user | Own PTYs, processes, desktop, and client sockets | Survives with zero viewers |
| Pane processes | same user | Shells and applications selected by the profile/class | Live within the session |
| Remote `ssh(1)` | user on the client machine | Verify the host key, provide credentials, and transport the terminal | Lasts as long as the connection |

The global `sshd` daemon must not be confused with the per-user, per-session
SuperTerm daemons. Restarting the SSH listener is not the same as closing
desktops: systemd uses `KillMode=process`, launchd uses
`AbandonProcessGroup`, and SuperTerm daemons already live in independent
process sessions/groups.

Conceptually, every connection proceeds from the root listener to OpenSSH's
privilege separation: privileged monitor, authentication, and a session
process reduced to the authenticated account's UID, GID, and groups. The
exact arrangement and names of these processes may vary between OpenSSH
versions. When creating a session, SuperTerm uses `setsid` and a double
`fork`; the final daemon is detached from the SSH PTY and reparented to the
system reaper, with standard input/output attached to `/dev/null`. Pane
processes remain under that daemon. For a root login, the SuperTerm portion
and its panes naturally retain UID 0.

The instance owns separate keys and an independent `sshd_config`, but it
deliberately reuses the host's `sshd` PAM policy—normally
`/etc/pam.d/sshd`—including account, credential, and session open/close hooks.
Separating `/etc/superterm/sshd` neither isolates nor duplicates PAM.

## Exact connection path

1. `ssh` connects to an address and port declared in `listen`. The client
   verifies this instance's **host** key, which is independent of the
   machine's regular `sshd` host key.
2. OpenSSH negotiates the encrypted channel and authenticates an account
   known to NSS. Depending on `server.ini`, it accepts a password allowed by
   PAM, an authorized public key, or either one.
3. OpenSSH requires the account to have an existing, executable shell. The
   configured PAM policy can deny the account because it is locked or
   expired, because of time restrictions, or for another reason even after a
   key has been accepted. OpenSSH then opens the PAM session, creates a PTY,
   and drops the process to that account's UID, GID, and groups.
4. `ForceCommand` replaces any requested shell with the fixed
   `superterm --ssh-entry` path. OpenSSH passes it to the account's login
   shell with `-c`; the path is validated as a safe literal and no remote
   text is concatenated to it. The configuration has already rejected
   forwarding, X11, agent forwarding, client environment variables, user RC
   files, and subsystems.
5. The entry checks `SSH_CONNECTION` and `SSH_TTY`. It also requires
   `SSH_ORIGINAL_COMMAND` not to exist: even an empty remote command is
   treated as an `exec` request and rejected.
6. SuperTerm resolves a session for **that account**, never for the whole
   system. In `last` mode it first tries the most recent live session; it then
   uses `default_session`, `default_profile`, and finally `session`.
7. A POSIX lock keyed by user and name serializes initial creation. Two
   simultaneous logins may both attach to the same daemon, but they cannot
   publish two sessions with the same name.
8. If the socket is already live, the client attaches. If it does not exist,
   the first client builds the profile—or an empty desktop—publishes the
   daemon, and reconnects to it through the same Unix protocol.
9. Pane output reaches the daemon, which updates canonical state and
   broadcasts the result to all viewers. Keyboard input is processed in
   order; structural operations use the shared session's revision and pane
   locking rules.
10. Detach, closing the terminal emulator, timeout, or loss of network removes
    only that viewer. OpenSSH closes the channel and its outer PTY; EOF on the
    Unix socket invokes `DropClient`, not `FRAME_CLOSE`. The panes and daemon
    remain alive, and the next connection receives a canonical snapshot.

Encryption terminates in OpenSSH on the same host. From there to the session
daemon, communication uses a local socket protected by Unix permissions.
There is no double encryption, custom SSH serialization, or private key
handling inside SuperTerm.

## Three kinds of keys that must not be confused

| Item | Location | Who owns the secret | Purpose |
|---|---|---|---|
| Host key `ssh_host_ed25519_key` | server, `/etc/superterm/sshd` | server root | Identifies the service to clients |
| Authorized public key | server, central store or `~/.ssh/authorized_keys` | Contains no secret | Authorizes a client identity for an account |
| User private key | client machine, normally `~/.ssh/id_*` | client user | Proves ownership of the authorized public key |

`authorize` accepts only the `.pub` file. Copying a private key to the server
is unnecessary and weakens security. The entry written to `known_hosts` does
not authorize the user either: it protects the client from a counterfeit
server.

## Persistent state

This instance's configuration, host identity, and central store are separate
from the system's regular SSH service:

```text
/etc/superterm/sshd/
|-- .admin.lock
|-- server.ini
|-- sshd_config.generated
|-- ssh_host_ed25519_key
|-- ssh_host_ed25519_key.pub
`-- authorized_keys/
    |-- german
    `-- root
```

SuperTerm does not modify `/etc/ssh`. Depending on `user_authorized_keys`,
OpenSSH may also read the account's regular `~/.ssh/authorized_keys`, but
SuperTerm neither writes nor deletes it. It uses only the system `sshd` at
`/usr/sbin/sshd` or `/usr/bin/sshd` and verifies that `/etc/ssh` is a
protected path. OpenSSH would run `/etc/ssh/sshrc` even before the
`ForceCommand` despite `PermitUserRC no`; because there is no directive that
disables it, SuperTerm refuses to start if that file exists. This explicit
check avoids promising isolation that OpenSSH cannot provide through
configuration. The directory, configuration, and central authorized-key
files are owned by root and are not writable by other users. The private host
key has mode `0600`. Authorized keys are public, and every central file is
named after a real system user. With `StrictModes yes`, OpenSSH also checks
the ownership and permissions of the user's home and private
`authorized_keys` before accepting a user key.

`sshd_config.generated` is an artifact: do not edit it. SuperTerm builds a
candidate, checks it with the same `sshd` that will run it, and replaces the
artifact only after both `sshd -t` and `sshd -T` pass. An upgrade preserves
`server.ini`, server identity, and every authorization.

`server.ini` is pending state, while `sshd_config.generated` is the latest
accepted state. `check` validates the pending state without publishing it.
`restart` temporarily publishes an already validated candidate, restarts the
service, and checks its health; if anything fails, it attempts to restore the
previous artifact, service descriptor, and service state. On every start, the
wrapper revalidates the directives that SuperTerm sets as its security
boundary. It does not attempt to pin every cipher, KEX, MAC, key algorithm, or
the PAM policy of the installed OpenSSH.

Each account's state is not stored in `/etc/superterm/sshd`:

```text
~/.superterm/
|-- superterm.ini                 that user's preferences and SSH route
`-- sessions/
    |-- NAME.ini                 live daemon identity/metadata
    `-- NAME.sock                private local transport, mode 0600
```

Processes and screen contents remain live in daemon memory; they are not
serialized in `NAME.ini`. The sidecar publishes discovery metadata,
including the PID and process birth identity; the actual connection boundary
is the private directory, the `0600` socket, and its live listener. When
removing a session, the daemon verifies that it still owns the socket inode
before deleting it. Manually deleting these files while the daemon is alive
is not a valid way to close a session. Use the SuperTerm menu or its session
CLI.

| State | Survives SSH disconnection | Survives `sshd` restart | Survives host restart |
|---|---|---|---|
| SuperTerm daemon, panes, and processes | Yes | Yes | No |
| User preferences/profiles | Yes | Yes | Yes |
| Host key and centrally authorized keys | Yes | Yes | Yes |
| `ssh_last_session` route | Yes | Yes | Yes, but it is used only if the session remains live |

A live session is its own exact restoration: detach neither saves nor reloads
a desktop. After a host restart, that live process no longer exists; the next
entry creates a new session from the configured profile.

## Configuration

The public, stable format is `/etc/superterm/sshd/server.ini`:

```ini
[server]
config_version=1
listen=127.0.0.1:8022,[::1]:8022
allow_root=0
password_authentication=1
managed_authorized_keys=1
user_authorized_keys=1
```

`listen` is a comma-separated list of one to 32 TCP endpoints. Each entry has
its own port, from 1 through 65535, so different interfaces and ports can be
combined. This version does not open UDP listeners:

```ini
listen=127.0.0.1:8022,[::1]:8022,192.0.2.20:2222,[2001:db8::20]:2222
```

IPv6 addresses are always enclosed in brackets. To listen on every interface,
use `0.0.0.0` and `[::]` explicitly. The initial value listens only on the
loopback interfaces; publishing the service on a network requires a deliberate
configuration change.

`allow_root=0` rejects root even if `authorized_keys/root` exists. With
`allow_root=1`, root remains restricted to public-key authentication and the
forced SuperTerm interface: the root password is never accepted.

The three authentication options are independent:

- `password_authentication=1` accepts a password through the `sshd` service's
  PAM policy. SuperTerm neither receives nor stores that password.
  `KbdInteractiveAuthentication` remains disabled so that two equivalent
  password paths are not exposed.
- `managed_authorized_keys=1` reads the keys managed by SuperTerm from
  `/etc/superterm/sshd/authorized_keys/USER`.
- `user_authorized_keys=1` reuses each account's regular public keys from
  `.ssh/authorized_keys`. Private keys are never copied to the server: they
  remain on the SSH client.

The resulting effective policy is:

| Password | Any key source | Result for regular users | Result for root |
|---|---|---|---|
| `0` | yes | Public key only | Key only if `allow_root=1` |
| `1` | no | Password/PAM only | Requires `allow_root=0`; with `allow_root=1` the entire configuration is invalid |
| `1` | yes | Password **or** public key | Key only if `allow_root=1` |
| `0` | no | Invalid configuration | Invalid configuration |

When both paths are active, `AuthenticationMethods any` means "any of the
enabled methods," not "without authentication." SuperTerm verifies this
semantic in the effective output from `sshd -T`. It does not configure
two-factor authentication; doing so would require a different policy and
specific tests.

At least one of these paths must remain enabled. `allow_root=1` also requires
a key source because root password authentication remains prohibited. A new
`server.ini` explicitly writes `1/1/1`. For safety, a version 1 file created
by an older version that lacks these three keys retains its old `0/1/0`
policy; explicitly add them and run `check` and `restart` to adopt the new
policy.

After editing `server.ini`, validate it before restarting:

```sh
sudo superterm ssh-server check
sudo superterm ssh-server restart
```

An invalid configuration neither replaces the latest generated configuration
nor stops an already working service.

## Applied example: access for `german` and `root`

The accounts must exist in the system user database. To let `german` log in
with either a password or a key, and `root` with a key only, use this section:

```ini
[server]
config_version=1
listen=192.168.0.214:8022
allow_root=1
password_authentication=1
managed_authorized_keys=1
user_authorized_keys=1
```

Then authorize at least one public key for root. Another key can be authorized
for `german`; without one, `german` can still use a password accepted for that
account by the `sshd` PAM policy:

```sh
sudo superterm ssh-server authorize german /path/to/superterm_client.pub
sudo superterm ssh-server authorize root /path/to/superterm_client.pub
sudo superterm ssh-server check
sudo superterm ssh-server restart
sudo superterm ssh-server list-keys german
sudo superterm ssh-server list-keys root
```

This does not enable a special SuperTerm password. OpenSSH consults the
`sshd` PAM policy, which may use `pam_unix`, LDAP, or another host backend.
`PermitRootLogin` is generated as `prohibit-password`, so a root password
never works on this service even when `password_authentication=1`.

These options are not an exclusive user list. With password authentication
and `user_authorized_keys` enabled, any other valid NSS account that passes
PAM and has an executable shell can authenticate under the same policy.
`allow_root` controls only the root exception. Restricting the service
exclusively to `german` and `root` would require an explicit allowlist in a
future version or an equivalent restriction in the host's PAM policy.

Connection commands for this example:

```sh
ssh -p 8022 german@192.168.0.214
ssh -p 8022 root@192.168.0.214
```

If the private key has a nonstandard name:

```sh
ssh -tt -o IdentitiesOnly=yes \
  -i ~/.ssh/superterm_192_168_0_214_ed25519 \
  -p 8022 german@192.168.0.214
```

`-tt` forces PTY allocation; from a normal interactive terminal it is usually
unnecessary. `IdentitiesOnly=yes` prevents the agent from trying other keys
and is useful for diagnostics, but it is not required when the expected key
is already a regular client identity.

## Installation and service

The `sshd` binary must be installed. On Debian/Ubuntu it is supplied by
`openssh-server`; macOS includes `/usr/sbin/sshd`. SuperTerm runs a separate
instance in the foreground, supervised by systemd on GNU/Linux or by a
LaunchDaemon on macOS.

Setup is idempotent:

```sh
sudo superterm ssh-server setup
sudo superterm ssh-server status
```

`setup` creates `server.ini` and the Ed25519 host key only when they are
missing. On every invocation, it rebuilds and validates the generated artifact
and the service descriptor, then enables the service at boot. It never
replaces the existing **private** key, authorizations, or `server.ini`; it
normalizes the private key to `0600` and can regenerate its public half if it
is missing or does not match.

In a real installation, the absolute path to `superterm` and every ancestor
directory must be owned by root and not writable by the group or other users.
This prevents someone from replacing the `ForceCommand`. On macOS, use a
dedicated root-protected hierarchy such as `/opt/superterm/bin`.
`/usr/local/bin` is suitable only when that directory and all its ancestors
are also owned by root and not writable by others; a user-writable Homebrew
path is deliberately rejected for this privileged service.

`make install` only copies the program and never enables a privileged service
unexpectedly. After the first installation, or after updating the binary,
run `sudo superterm ssh-server setup` to build and validate the descriptor for
that version. The operation preserves `server.ini`, the keys, and the
authorizations.

Service administration:

```sh
sudo superterm ssh-server enable
sudo superterm ssh-server disable
sudo superterm ssh-server restart
sudo superterm ssh-server status
```

Each command has a deliberately distinct scope:

| Command | Reads pending state | Publishes configuration | Changes service manager state |
|---|---:|---:|---:|
| `setup` | Yes | Yes, after validation | Installs/updates and enables the descriptor |
| `check` | Yes | No | No |
| `restart` | Yes | Yes, after validation | Restarts and checks health; rolls back on failure |
| `enable` | No; uses the accepted artifact | No | Enables and starts |
| `disable` | No | No | Stops and disables the listener |
| `status` | No | No | Query only |
| `uninstall-service` | No | No | Removes a descriptor recognized as its own |

Administration takes an exclusive lock with a bounded wait. Changes are
written to regular temporary files using `O_EXCL`/`O_NOFOLLOW`, validated,
and renamed within the protected directory. `restart` captures the generated
artifact, service descriptor, and previous service state; if activation or
the health check fails, it attempts to restore all three exactly. Host keys,
authorizations, and `server.ini` are never deleted as part of that rollback.

The lock covers operations that validate or mutate state, including `check`.
`status` and help only query state and do not take it; `list-keys` first
ensures the protected tree and then enumerates it, also without taking this
lock. The exclusive `run` wrapper is neither a read nor an administrative
operation: it validates the published artifact and starts the listener.
Every process sees complete generations because publication uses atomic
renames.

The internal `ssh-server run` command is not an administration path. It is
the wrapper used by systemd/launchd: it revalidates the accepted artifact
with the installed `sshd` and finally `exec`s `sshd -D -e`. The service's
main PID therefore becomes OpenSSH itself, without an additional SuperTerm
supervisor.

Service-manager and runtime paths:

- GNU/Linux: `/etc/systemd/system/superterm-sshd.service` and
  `/var/run/superterm-sshd.pid`.
- macOS: `/Library/LaunchDaemons/org.superterm.sshd.plist` and the same private
  PID file under `/var/run`.

`restart` does not enable a service that has already been disabled. After
`disable`, use `enable`; `setup` also prepares and enables a complete
installation.

To remove only the service-manager integration:

```sh
sudo superterm ssh-server uninstall-service
```

The command stops and disables only a descriptor that it recognizes as its
own. It preserves `server.ini`, the host keys, and every authorized key in
`/etc/superterm/sshd`, so a reinstall retains the identity. A versioned
ownership marker and the service's invariant fields allow strict recognition
of a descriptor from an earlier version even as its contents evolve.
`make uninstall` first runs this same operation; with `DESTDIR`, it modifies
only the packaging tree and never the host's service manager. An unprivileged
local uninstall does not touch the service manager either: a valid root
service cannot point to that user-owned binary.

On GNU/Linux, output from `sshd -e` goes to the unit journal. The macOS
descriptor does not configure `StandardOutPath` or `StandardErrorPath`, so it
does not promise an equivalent persistent file; `ssh-server status` shows the
state and last result retained by launchd. Client and session-daemon failures
continue to use `SUPERTERM_DEBUG`, `SUPERTERM_CRASH_DIR`, and the mechanisms
described in `DEBUGGING.md` and `HEAP_DEBUGGING.md`.

## Authorizing central keys

Only the SuperTerm administrator modifies the central store. It validates the
user, file, and key with OpenSSH tools, rejects `authorized_keys` options,
discards unauthenticated comments, prevents duplicates, and replaces the file
atomically:

```sh
sudo superterm ssh-server authorize german /path/to/id_ed25519.pub
sudo superterm ssh-server list-keys german
sudo superterm ssh-server revoke german SHA256:FINGERPRINT
```

Authorizing or revoking affects new authentications; it does not disconnect
clients that are already logged in. The commands also have the Spanish
aliases shown by `superterm ssh-server help`. These commands do not modify the
account's own `.ssh/authorized_keys`; that second store remains under the
user's normal control and retains all OpenSSH semantics. For example, it may
contain options that further restrict an entry or a `cert-authority` line.
No per-key option can relax the global `ForceCommand` or prohibitions; a
`no-pty` option may authenticate the key, but causes the SuperTerm entry to be
rejected because it has no PTY.

## Connections and sessions

Normal interactive connection:

```sh
ssh -p 8022 german@192.168.0.214
```

An interactive client requests a PTY automatically. `ssh -tt` is necessary
only when invoked from an environment without a terminal or from one that
would not allocate it. OpenSSH tries its usual keys; if none matches and
password authentication is enabled, it requests the password that PAM will
validate for `german`. On the first connection, it displays the host-key
fingerprint and stores it in the client's `known_hosts`. The `-p` option must
precede the destination in portable OpenSSH syntax.

To shorten the command to `ssh superterm`, save the following on the client
without replacing any other entry in `~/.ssh/config`:

```sshconfig
Host superterm
    HostName 192.168.0.214
    Port 8022
    User german
    RequestTTY force
```

When using a key with a nonstandard name, also add an
`IdentityFile ~/.ssh/KEY_NAME` line.

The SSH entry resolves the per-user session through these options in
`~/.superterm/superterm.ini`:

- `ssh_session=last` (default) returns to the latest session that the user
  successfully entered through SSH. If the hint does not exist or the daemon
  is no longer alive, it uses `default_session`, then `default_profile`, and
  finally `session`.
- `ssh_session=default` ignores the latest route and always enters that
  default chain.
- `ssh_last_session` is a private hint that SuperTerm updates atomically only
  after a successful attach. It does not store desktops, panes, geometry, or
  processes and normally should not be edited.

If that session is already live, the client attaches without changing its
geometry. If it does not exist, the first connection creates it using
`default_profile`; a missing or unconfigured profile produces an empty
desktop. `default_session` determines the session **name**, not its initial
contents. Initial geometry comes from that first PTY. A per-user, per-name
lock prevents two simultaneous connections from creating two daemons.

The `Sessions` menu can create another session at any time. The dialog asks
for a name and a starting profile, and includes `<Empty (no profile)>` to
start with a desktop containing no windows. The `Profiles` menu can first
create an empty profile or save the current desktop as a profile. Creating or
changing sessions only detaches the client from the previous session; it does
not destroy the previous daemon. With `ssh_session=last`, detaching and
reconnecting returns precisely to that new session, not to an earlier fixed
session.

Detach from the menu, closing the SSH window, or losing the network preserves
the session. `Exit` is different: it sends an explicit session close; if other
viewers remain, only that client exits, and if it was the last viewer, it stops
and removes the session. With zero viewers, a session whose panes have all
exited may reap itself after its grace period; a deliberately empty desktop
with zero panes remains available for reattach.

### Multiple clients on the same session

Attach does not create private geometry. Everyone receives the same pane
tree, positions, sizes, minimized/maximized/fullscreen state, shared focus,
contents, and output order. A client on which the desktop does not physically
fit displays that same view inside its terminal; it does not force the daemon
to create a second desktop.

The connection of a viewer does not by itself resize the PTYs. A subsequent
resize accepted by the program is a canonical operation and is propagated to
everyone. When host geometries differ, operations that require a common area
(such as synchronized fullscreen) are limited to the smallest compatible
viewport. Raw fullscreen passthrough (`prefix f`, `Ctrl-Q f` by default) is
used only when the physical geometries match; otherwise the shared IDE
renderer remains active.

Input from multiple clients is delivered in the order in which the reactor
accepts it. Structural changes to a window are serialized with revision and
per-pane locking, so two users can operate concurrently on different panes
without mixing commits. The SuperTerm clipboard is the deliberate exception:
it is client-local memory and does not travel through the session.

Each daemon accepts no more than eight interactive viewers. Ephemeral control
CLI connections use separate slots and do not consume any of those eight.
Output to each viewer has a bounded buffer: a client that stops reading and
exceeds the congestion threshold is disconnected independently, without
blocking the PTYs or the other clients.

Client and daemon must speak the same attach protocol version
(`ATTACH_PROTO_VER`, currently 15). After a binary update, an old daemon may
reject a new client—or vice versa—instead of interpreting an incompatible
snapshot. Explicitly close that old session or temporarily use a client from
the same version; never force the attach.

## Verification and diagnostics

### Checks after installation or upgrade

```sh
sudo superterm ssh-server check
sudo superterm ssh-server status
sudo superterm ssh-server list-keys german
ssh -vv -p 8022 german@192.168.0.214
```

`check` validates only the pending `server.ini`. To verify exactly what
OpenSSH is running, inspect the accepted artifact:

```sh
sudo /usr/sbin/sshd -T \
  -f /etc/superterm/sshd/sshd_config.generated
```

On usrmerge systems the binary may be at `/usr/bin/sshd`; SuperTerm selects
and validates one of these two protected paths. Effective output must include,
among other settings, the desired `listenaddress`, the absolute
`forcecommand`, `disableforwarding yes`, the exact `authorizedkeysfile`
sources, and the expected combination of `passwordauthentication`,
`pubkeyauthentication`, and `authenticationmethods`.

On GNU/Linux, query listener events with:

```sh
sudo journalctl -u superterm-sshd.service -b
```

`LogLevel VERBOSE` records the account, source, method, and accepted-key
fingerprint without logging passwords or private keys. On macOS, use
`superterm ssh-server status` and the launchd logging tools; the descriptor
does not promise a private text file.

### Common failures

| Symptom | Probable cause | Safe check |
|---|---|---|
| `Connection refused` | Service stopped or address/port not published | `ssh-server status`, `server.ini`, system listener |
| `Address already in use` during activation | Another process occupies an address/port from `listen` | Identify the listener; do not kill processes without verifying their owner |
| Timeout before authentication | Wrong interface or firewall | Compare the destination IP with every `listen` entry |
| Unknown host-key warning | First connection to this instance/port | Compare with `ssh-keygen -lf /etc/superterm/sshd/ssh_host_ed25519_key.pub` on the server |
| Host key changed | The identity was replaced or the connection reaches another machine | Do not blindly delete `known_hosts`; first verify the server fingerprint |
| `Permission denied (publickey)` | Wrong private key, unauthorized public key, or permissions rejected by `StrictModes` | `ssh -vv`, `list-keys`, ownership/modes of `~/.ssh` |
| Password requested despite having a key | None of the offered identities was accepted | Try `IdentitiesOnly=yes -i PATH` and inspect the fingerprint; do not copy private keys to the server |
| `root` cannot log in with a password | Mandatory behavior | Use a key and check `allow_root=1` |
| `interactive SSH PTY is required` | `ssh -T`, pipeline without a PTY, or noninteractive client | Request a PTY with `-t`/`-tt` |
| `remote commands and subsystems are disabled` | A command, SCP, or SFTP was requested | Connect without a command; these functions are not part of the service |
| Returns to a different session | The latest one is no longer live, mode `default` is active, or the hint belongs to another user | Inspect `[session]` and `superterm --list-sessions` under that account |
| Connection drops but panes remain | Detach through EOF/keepalive | This is expected behavior; reconnect |
| `check` rejects `/etc/ssh/sshrc` | OpenSSH would run it outside `ForceCommand` control | Audit/remove that global hook; do not bypass validation |
| Unprotected path rejected | The binary or an ancestor directory is writable/not owned by root | Install into a root-owned hierarchy and run `setup` again |
| Public host key missing or mismatched | The `.pub` does not derive from the retained private key | `setup` can repair only the public half; verify the fingerprint afterwards |
| `protocol version ... need ...` | Client and daemon come from incompatible builds | Explicitly close the old session or use the matching binary |

Never debug by passing a password in argv, `server.ini`, a URL, or a log.
`sshpass` is used only by **outbound** SSH pane classes; it does not
participate in this service's inbound authentication.

### Automated tests covering the integration

After building the test binary, the main checks are:

```sh
make test-runtime
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
  python3 test/ssh_server_config_test.py
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
  python3 test/ssh_entry_test.py
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
  python3 test/ssh_transport_test.py
SUPERTERM_TEST_BIN="$PWD/bin/superterm-test" \
  python3 test/ssh_service_uninstall_test.py
```

- `ssh_server_config_test.py` uses a real `sshd` to validate the
  authentication matrix, `-t`, `-T`, atomic publication, rollback,
  permissions, keys, and fail-closed policy.
- `ssh_entry_test.py` tests simultaneous creation, `last/default` selection,
  detach, reattach, profiles, and an empty desktop over the session protocol.
- `ssh_transport_test.py` starts an isolated OpenSSH TCP listener and connects
  with the standard `ssh` client; it covers two viewers, abrupt loss, resize,
  rejection of exec/SFTP/forwarding, and reattach.
- `ssh_service_uninstall_test.py` tests descriptor ownership, service-manager
  failures, rollback, and preservation of all `/etc/superterm/sshd` state
  during uninstall.

The complete suite runs with `make test`. Some privileged paths are explicitly
skipped when the test account cannot reproduce them; an identified `SKIP`
must not be presented as an executed test.

## Implementation map and audited sources

The SuperTerm flow can be followed without gaps through these units:

| File | Main points |
|---|---|
| [`src/st_ssh_server.pas`](../src/st_ssh_server.pas) | `BuildGeneratedConfig`, effective `sshd -T` validation, activation/rollback, systemd/launchd, and key administration |
| [`src/st_ssh_entry.pas`](../src/st_ssh_entry.pas) | `PrepareSshEntry`, initial-creation lock, `last/default` route, and `ssh_last_session` update |
| [`src/superterm.lpr`](../src/superterm.lpr) | Early dispatch of `ssh-server` and the reserved `--ssh-entry` argument |
| [`src/st_fvui.pas`](../src/st_fvui.pas) | Deferred profile construction, attach, and promotion of the workspace to the daemon |
| [`src/st_server.pas`](../src/st_server.pas) | Unix socket, v15 protocol, snapshots, reactor, clients, PTYs, `DropClient`, and double fork |
| [`src/st_config.pas`](../src/st_config.pas) | Atomic reading and writing of the per-user SSH route policy |

The audited OpenSSH Portable reference is `V_10_5_P1`, commit
[`b3f7344209832eea8ece447d871ea748767c444b`](https://github.com/openssh/openssh-portable/commit/b3f7344209832eea8ece447d871ea748767c444b).
The following were verified in the study copy at
`/opt/openssh-portable-10.5p1`:

- `sshd.c` for host-key loading and the listener;
- `sshd-session.c` for pre/post-auth privilege separation;
- `auth.c`, `auth2-pubkey.c`, and `auth2-pubkeyfile.c` for accounts,
  `AuthorizedKeysFile`, signatures, and `StrictModes`;
- `auth-passwd.c` and `auth-pam.c` for passwords, account control,
  credentials, and the PAM session;
- `session.c` for PTYs, `SIGWINCH`, `ForceCommand`, the environment, RC files,
  and execution of the shell with `-c`;
- `serverloop.c` and `monitor.c` for channel, PTY, and monitor shutdown.

The `/opt` copy is audit material only and is not a dependency of the
installed program. At runtime, SuperTerm exclusively uses the system's
protected OpenSSH and rechecks its effective configuration.

## Security and compatibility limits

- Only accounts known to NSS whose shell exists and is executable are
  accepted. The `sshd` PAM policy can enforce locking, expiration, schedules,
  and other rules; its account check also runs after a valid public key.
- Effective authentication is exactly `password`, `publickey`, or either one,
  according to `server.ini`. Keyboard-interactive, GSSAPI, hostbased,
  global `TrustedUserCAKeys`, and external authorization commands remain
  disabled. If the account's own `authorized_keys` is enabled, that file
  retains OpenSSH options such as `cert-authority`; SuperTerm's central store
  accepts only plain keys without options.
- `ssh host command`, `ssh -T`, SCP/SFTP, and every kind of forwarding are
  rejected.
- The forced command uses an absolute SuperTerm path and accepts no client
  text.
- The wrapper rejects `Match` and `Include`, checks the effective policy with
  `sshd -T`, and allows neither key sources other than the two configured
  sources, client environment variables, nor subsystems.
- User names, addresses, ports, and keys are validated before reaching an
  OpenSSH file or an external process.
- The SSH daemon does not interpret the binary session protocol and never
  exposes the Unix socket over TCP.
- A machine needs the OpenSSH `sshd` binary, a build with working PAM support
  for password authentication, and a platform supported by SuperTerm/FPC.
  This architecture can therefore replace interactive access on compatible
  GNU/Linux and macOS servers, but not literally on every embedded device that
  has only Dropbear, lacks PAM, or cannot run SuperTerm.

The implementation deliberately delegates OpenSSH's `poll` loops,
authentication, PTY handling, and child reaping to OpenSSH.
