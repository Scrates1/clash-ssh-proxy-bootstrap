# TODO

## Optional per-user transparent proxy on Linux

- [ ] Design and implement an opt-in transparent proxy mode that routes traffic
  for selected Linux users without requiring applications to honor proxy
  environment variables.

The implementation should:

- remain disabled by default and preserve the existing environment-variable
  mode as the safe default;
- scope interception by UID or an equivalent isolated execution context so
  unrelated users are unaffected;
- exclude the SSH control connection, reverse tunnel, loopback, and required
  management traffic to prevent routing loops and lockouts;
- define explicit behavior for TCP, UDP, DNS, IPv4, IPv6, and private-network
  destinations rather than claiming unsupported traffic is proxied;
- validate that the upstream proxy or VPN transport supports every enabled
  protocol;
- require and document the minimum administrative privileges;
- provide idempotent install, health-check, disable, uninstall, and automatic
  rollback paths; and
- include isolation, loop-prevention, failure-recovery, and privacy tests.
