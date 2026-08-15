# Usage

## From application code

```ruby
Observatory.current                     # the execution being measured, or nil
Observatory.annotate(:full_rebuild)     # flag it; survives sampling, shows in the explorer
Observatory.retain!                     # keep this trace regardless of sampling

Observatory::Instrumentation.suppress { … }   # do something uninstrumented
```


## What it collects

Per HTTP request and per Sidekiq job: duration; route template (never the literal
URL); total ActiveRecord lookups split into executed / cached / schema /
transaction; normalised query fingerprints with per-shape counts, timings and a
representative application call site; view, cache and outbound-HTTP time;
estimated allocations and GC; connection-pool gauges; thread-seconds of capacity
consumed; traffic classification and an anonymised client identifier; the active
release.


## Privacy

No raw IP addresses (HMAC with a rotating salt, and the mechanism disables itself
rather than pretend if no secret is configured). No bind values — literals are
replaced during fingerprinting, *before* anything is stored, so a value cannot
reach the database even by accident. No request or response bodies, no
authentication headers, no query strings, no URLs for outbound calls (host only —
this application puts API keys in Steam query strings and bearer tokens in PSN
headers). Route templates, not paths.

