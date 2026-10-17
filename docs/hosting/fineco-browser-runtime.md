# Fineco browser runtime

The Fineco login flow launches a temporary graphical Chromium session inside the
existing Sure web container. The user completes Fineco's login in that browser;
Sure does not collect or store the user's Fineco password. The temporary browser
profile stays in the container runtime. RFB can carry clipboard data from that
browser session to the viewer in the user's browser, so clipboard contents are
not confined to the container. The Sure UI has no credential-paste
helper, and application code does not persist clipboard values or include them
in Rails logs or status responses.

The browser runs as the dedicated `fineco-browser` UID 1001. Rails stays UID 1000,
and `/rails` is owned by Rails with mode `0750`. A root-owned setuid supervisor
with mode `4750` starts the fixed Xvfb, x11vnc, and Chromium commands, gives them
only a small environment, and owns their bounded lifetime and profile cleanup.
The supervisor accepts only a random flow locator and the Rails parent PID; it
does not accept command, path, environment, or signal arguments. Chromium's
profile and runtime lock live under `/run/sure-fineco`.

Configure the existing `web` service only. This is a deployment proposal; it
does not add a service or alter deployment files:

```yaml
services:
  web:
    init: true
    environment:
      FINECO_BROWSER_ENABLED: "true"
    security_opt:
      - seccomp:./config/docker/fineco-seccomp.json
    tmpfs:
      - /run/sure-fineco:rw,nosuid,nodev,noexec,size=256m,mode=0711
```

The custom seccomp profile is based on the upstream [Moby profiles default
seccomp file at commit `4b8214fc4971e06172938a1f1554ccff6647ee80`](https://github.com/moby/profiles/blob/4b8214fc4971e06172938a1f1554ccff6647ee80/seccomp/default.json).
The unmodified base SHA-256 is
`6416b47770785a41ac59073cdc77d9fe98517df2799dc83ef207e622de3053f6`; the
Sure profile adds the measured namespace argument rules described below. The
upstream Apache License 2.0 and modification notice are retained in
`config/docker/LICENSE-MOBY-PROFILES.txt` and
`config/docker/NOTICE-fineco-seccomp.txt`.

Leave `FINECO_BROWSER_ENABLED` unset on the worker and keep `WEB_CONCURRENCY=1`
for the web service. The runtime fails closed when its root-owned Chromium policy,
helper, user/group layout, `/rails` permissions, or the single-worker requirement
does not match. The seccomp profile narrowly admits Chromium's measured
individual user, PID, and network namespace flags for `clone`/`unshare`, plus
the measured combined `USER|PID|NET` `clone`; its full namespace mask rejects
other namespace flags in those calls. It does not add `SYS_ADMIN`, disable
seccomp, enable privileged mode, or disable Chromium's sandbox. The runtime
requires a rendered Chromium renderer whose user namespace differs from the
browser process and whose status confirms seccomp filters, no-new-privileges,
and zero effective capabilities.

The profile and its contents are defense in depth. Filesystem access is separated
by the browser UID and Linux ownership; Landlock is unavailable on the target Pi
kernel. The browser shares the container kernel and network namespace with Sure,
so this is not a boundary for hostile browser or kernel code. The loopback VNC and
CDP listeners are not published, and the browser UI never receives their ports.
The Chromium broker runs as UID 1001 in the same container network namespace as
Sure and can reach internal services. A native broker or browser-UID compromise
could reach unauthenticated Redis/cache/queue services; the renderer sandbox and
managed navigation are not network isolation. This does not describe normal
authorized browser HTTP or WebSocket traffic as raw Redis access.
The same-origin `/fineco_login/stream` bridge requires the signed Sure session,
the exact expected Origin, and repeated owner/session authorization checks. Its
query string contains only the nonsecret flow ID. Packaged noVNC assets are served
from `/fineco-novnc/` by the app; the bridge adds no Docker service or websockify.

The login flow has a monotonic twenty-minute limit. An authorized stop, logout,
session demotion, application shutdown, failed startup, or timeout closes the
VNC bridge and tells the supervisor to terminate and reap browser processes before
removing the profile. The next flow takes an independent root-owned lifecycle
lock, removes stale UID 1001 processes and profiles, and checks the fixed display
socket and VNC/CDP ports before launch. If the supervisor itself is killed, the
current Rails process fails closed and keeps its runtime lock; restart the web
process before another flow can start. The next supervisor startup removes stale
browser processes and profiles before opening a replacement flow. The web
container's tmpfs clears profile files on container restart.

Portfolio capture is gated by the code capability
`Provider::Fineco.verified_identity_contract?`; request parameters and environment
variables cannot enable it. That capability is currently false, so the initial
flow is diagnostic-only: it opens the browser and viewer, reports
`setup_verification_required`, and remains available until stop or timeout. In
this mode the runtime does not enable CDP Network observation, inspect cookies or
response bodies, invoke the persistence callback, or auto-finish after a portfolio
request. Enabling capture later requires a reviewed identity-verification
implementation and its regression evidence.

When that capability is enabled, the runtime recognizes only the exact Fineco
portfolio-summary GET with the single `type=sintesi` query value, a successful
recognized response, and the bank-generated account and dossier index headers.
It reads only a secure, domain- and path-matching `gsessionid` cookie from CDP and
passes that cookie, the selected indices, and capture time to the app callback in
memory. The callback rechecks the initiating Sure session, calls the fixed Fineco
verification client, and persists only after validation and encryption. Browser
output, clipboard contents, page bodies, cookie values, and local debugging ports
are never written to logs or status responses.

## Verification

Run focused tests and lint in the normal Sure development container:

```sh
bin/rails test test/lib/fineco/browser_login_runtime_test.rb
bundle exec rubocop lib/fineco/browser_login_runtime.rb \
  lib/fineco/browser_login_runtime/cdp_connection.rb \
  lib/fineco/browser_login_runtime/capture_observer.rb \
  lib/fineco/browser_login_runtime/web_socket_endpoint.rb \
  lib/fineco/browser_login_runtime/asset_endpoint.rb \
  test/lib/fineco/browser_login_runtime_test.rb
```

For ARM64 image changes, verify the exact final image in a disposable container:
confirm the rendered Chrome sandbox and namespace/seccomp status; test that the
browser UID cannot read Rails files or the Rails process environment and file
descriptors; verify the helper rejects UID 1001; exercise normal, EOF, timeout,
and abrupt-parent cleanup plus stale-profile recovery; and check exact loopback
listeners and reserved-socket handling. Verify raw-RFB pointer and normal
keyboard input with synthetic text only;
an RFB handshake alone does not prove input delivery. A running browser or a
passing source test alone does not establish these runtime properties. Do not
test with real Fineco credentials or production mounts.
