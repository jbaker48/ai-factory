# Design

Where seams go, for the planner choosing each task's seam and the adversarial
reviewer checking them. A seam is the public interface a task's test calls.
The target's `AGENTS.md` and its ADRs override anything here.

## Rules

- **Prefer deep modules.** A good module hides a lot of behaviour behind a
  small interface: few entry points, few parameters, little the caller must
  know. A module whose interface is about as big as its body is shallow; it
  adds a name without hiding anything.
- **Apply the deletion test.** Imagine deleting the module and inlining its
  body into each caller. If the callers get no more complex, the module was
  pulling no weight and is not a seam worth testing at. If they would each
  have to repeat real logic, it is.
- **One adapter is a hypothetical seam; two make it real.** An interface with
  a single implementation is a guess about future change. Don't add one, or
  test through one, just to have a seam. It earns its place when a second
  implementation exists (a fake for a system boundary counts), or when the
  spec asks for the second.
- **The interface is the test surface.** Test through the seam and nothing
  past it: what callers call, with what callers see. If a test needs to reach
  behind the interface to check a behaviour, the seam is in the wrong place
  or the interface is missing something.

## What to flag

- **Testing past the interface**: a test that calls internals, reads private
  state or checks a side channel behind the task's seam, or a seam named on
  an internal helper when a public interface shows the same behaviour.
- **Single-adapter seam**: a new interface, abstraction or injection point
  with one implementation and no second in the spec, added so the code has
  something to mock.
- **Shallow pass-through module**: a new module that forwards its calls to
  another with little or no behaviour of its own, so it fails the deletion
  test.
