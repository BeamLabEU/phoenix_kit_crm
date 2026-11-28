# PR 48 · External references and catalogue supplier contacts

- **BUG - HIGH** · A failure stamping the catalogue row could leave the company, role, contact and membership committed. Repeating an import from an earlier snapshot could create another company when the supplier had no email or website to match.
- **BUG - MEDIUM** · The supplier import used the CRM changesets to decide which primary values fit. Those changesets counted graphemes for the destination fields. A phone containing 26 decomposed accented letters passed the 50-character validation but occupied 52 PostgreSQL characters, causing the supplier import to fail.
- **BUG - MEDIUM** · The new supplier fixtures omitted the two timestamps required by the installed catalogue schema. The simplified test table hid the error.
- **IMPROVEMENT - MEDIUM** · Checking for an existing person loaded the company's entire membership list and preloaded every contact. Only the existence of a live member with that name is needed.
