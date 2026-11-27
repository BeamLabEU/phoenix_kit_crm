# PR 47 · CSP lint and nonce support

- **BUG - MEDIUM** · The template lint exempted an entire tag when any attribute contained `src=`, `ColocatedHook`, or a nonce call. A `data-src` attribute on an inline script could therefore pass. The exemption needs to check the attribute name, tag kind and nonce expression.
- **BUG - MEDIUM** · The bundle lint accepted a created script or style when any of the next six lines mentioned `adoptStyle`. A call for a different element could silence the check. The current CRM hook only creates ordinary DOM elements.
- **IMPROVEMENT - MEDIUM** · The bundle inventory duplicated the manifest and omitted common JavaScript extensions. The handler scan also missed uppercase HTML attributes.

These are findings in the proposed lint. The existing hook escapes warning text and the embedded Client LiveView uses the core LiveView macro. The source checks cover this repository's side of the integration. Enforcing a policy in a browser also requires a configured host.
