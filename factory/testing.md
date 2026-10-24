# Testing

What a good test is, for builders writing tests and the code reviewer judging
them. The target's `AGENTS.md` says which runner and commands to use.

## Rules

- **Test behaviour through the public interface.** Call what callers call:
  the function, the CLI, the HTTP route, the page. A test that reads like a
  spec ("checkout with a valid cart succeeds") survives a rewrite of the
  internals; one that knows the internals breaks on every refactor.
- **Mock only at system boundaries.** Fake the network, the clock, the
  filesystem, a paid or slow third-party API. Never mock your own modules or
  internal collaborators to make a test pass.
- **Take expected values from an independent source.** A literal you worked
  out by hand, an example from the spec, a known-good output. Never recompute
  the expected value the way the code computes it.
- **Red first.** Run the new test before the code exists and check it fails
  for the reason you expect (the behaviour is missing), not for a typo or a
  missing import.
- **One behaviour per test.** Name it after the behaviour, not the method.

## What to flag

- **Implementation-coupled**: mocks internal collaborators, calls private
  functions, or checks a side channel (queries the database instead of using
  the interface). The tell: it breaks on a refactor that keeps behaviour the
  same.
- **Tautological**: the assertion can't disagree with the code, such as
  `expect(add(a, b)).toBe(a + b)`, a snapshot regenerated from the code under
  test, or a constant asserted equal to itself. It passes by construction.
- **No failing run**: a behaviour-changing task whose build report shows the
  test passing but never failing.
