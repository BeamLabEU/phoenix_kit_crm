# PR 48 follow-up

- Apply mode now locks the source row, checks its current link, and commits each supplier or manufacturer as a single transaction. A matched company is locked before its blank fields are filled. The importer broadcasts a new membership after commit.
- Tests force a stamp failure and check for orphaned companies and contacts. A retry with the original snapshot must return the first company's UUID.
- The CRM fields used for supplier primaries count Unicode code points. A regression test checks that an oversized primary phone can be skipped while the company still imports.
- Supplier fixtures supply both timestamps. The membership check uses a single database existence query with the live-contact and case-insensitive name filters.

Verification passed with `mix precommit` and all 1,094 tests against an isolated PostgreSQL database with catalogue V8 installed. The 10 supplier-contact tests also passed against the standalone CRM database.
