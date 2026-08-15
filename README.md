# Observatory

> Causal observability for Rails. Not "is it up?" — "what is consuming capacity,
> why, and what proves it?"

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![CI](https://github.com/studio51/observatory/actions/workflows/ci.yml/badge.svg)](https://github.com/studio51/observatory/actions/workflows/ci.yml)

Observatory is a self-contained Rails engine. `rails`, `slim` and `turbo-rails`
are its only hard dependencies; Puma, Sidekiq, MySQL and Redis are each detected
at boot and instrumented through a guarded adapter, so it installs cleanly into
an application that uses none of them.

It was built in-tree at `engines/observatory` inside
[games.directory](https://games.directory) and extracted here with its history.

Every infrastructure dashboard is green:

```
CPU: 40%      MySQL: idle      Redis: 7.6%      Puma: alive      Sidekiq: processing
```

And the site is down. Requests to one route are performing eighty-six thousand
ActiveRecord lookups each. Ninety-seven per cent of them are served by the
ActiveRecord query cache, so MySQL never sees them and stays idle. The time goes
into Ruby building queries, allocating objects and collecting garbage. Those
requests occupy every Puma thread. `/up` cannot get a thread, so the watchdog
concludes the process is dead and restarts a process that was merely full.

No component-level monitor can see this, because no component is unhealthy. What
is exhausted is *request capacity*, and what exhausted it is application code.

Observatory is built to say:

```
Puma request capacity exhausted

Primary contributor:  GET /steam/achievements/:id

Evidence:
- 6 concurrent requests, 14.4s median duration
- 59,349-86,359 ActiveRecord lookups per request
- 97.4% served from the ActiveRecord query cache
- 1.8-5.4s of estimated GC activity
- all request threads occupied
- MySQL remained mostly idle
- /up waited behind application traffic

Likely failure mode:  repeated ActiveRecord lookups inside a loop
Impact:               the watchdog restarted a living but saturated process
```

## Navigation

This repository adheres to the [Studio51 Solutions Common Standard v1](https://github.com/studio51/standards/blob/main/standards/common/v1/STANDARD.md), with each section documented properly in its own file.

- [Architecture](docs/ARCHITECTURE.md) — the audit, the design rules, the measured overhead and the risk register
- [Install & setup](docs/INSTALL.md)
- [Usage](docs/USAGE.md) — the API, what it collects, and what it deliberately does not
- [Runbook](docs/RUNBOOK.md) — how to operate, disable and debug it
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)

## License

[Apache-2.0](LICENSE), © 2026 Studio51 Solutions. See [NOTICE](NOTICE).
