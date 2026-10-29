# Security policy

## Supported versions

Only the latest release receives security fixes. Update with
`sudo ./bin/update`.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/jccd-dev/self-hosted-redis/security/advisories/new).
Do not open a public issue. Include the affected version, the steps to
reproduce, and the impact.

Expect an acknowledgement within 7 days. Fixed vulnerabilities are disclosed in
the release notes once a release is available.

Vulnerabilities in Redis, Restic, or Docker should be reported to those
projects. Report them here when this project's configuration exposes them.

## Scope

In scope: the installer and updater, credential and ACL generation, Compose
configuration, backup and restore scripts, and documentation that leads to an
insecure deployment.

Deployment model assumptions: operators run management scripts as root, Redis
is reachable only on the private `shared-services` network or VPS loopback, and
release integrity relies on HTTPS downloads from GitHub plus the published
SHA-256 checksum.
