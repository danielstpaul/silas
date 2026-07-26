# Security policy

## Reporting a vulnerability

Please use **GitHub's private vulnerability reporting** (this repository's
*Security* tab → *Report a vulnerability*) rather than a public issue. You'll
get an acknowledgement within a few days; please allow time for a fix before
any public disclosure.

## Supported versions

Pre-1.0, only the latest released version is supported — fixes ship as the
next release rather than as backports.

## Scope notes worth knowing

- The operator inbox and the JSON API are **deny-by-default**: they render 404
  until the host app wires `config.inbox_auth` / `config.api_auth`. Reports
  that assume an unauthenticated default are out of scope; reports that show a
  bypass of a wired auth lambda are very much in scope.
- Slack webhooks are signature-verified; email approval links are signed
  tokens with expiry. Bypasses of either are in scope.
- The built-in `:docker` sandbox is documented as **interim** and co-located
  with the host — running untrusted code there is out of scope by design
  (configure [hermetic](https://github.com/danielstpaul/hermetic) for real
  isolation). Escapes of a *hermetic-configured* setup should go to hermetic's
  own policy.
- Anything that lets a tool effect execute twice despite `transactional!`, or
  lets a parked turn resume against changed definitions without
  `NondeterminismError`, is a contract violation — please report it even if
  it isn't classically "security".
