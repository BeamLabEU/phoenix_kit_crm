# PR 47 follow-up

- The inline-tag check now reads attributes and matches the nonce kind to the element. Regression assertions cover external scripts, colocated hooks, misleading attributes and the wrong nonce kind.
- The bundle check now flags literal script or style element creation directly, consistent with the existing bundle. A future hook that needs to create either element should add a check for its stamping mechanism alongside the implementation.
- The scanner reads bundle paths from `PhoenixKitCRM.js_sources/0`, checks additional JavaScript and TypeScript extensions, and recognizes mixed-case HTML handlers.

Validation passed on the merge with main. The focused lint suite ran 10 tests with zero failures. The full suite reported 1,053 tests, zero failures and 15 optional catalogue exclusions. `mix precommit` passed, including the dependency audit and Dialyzer with the repository's existing ignore list.
