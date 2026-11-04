# Audits

| Review | Scope | Report |
| --- | --- | --- |
| Pashov Audit Group, 28 September to 12 October 2026 | The partner-lending contracts (Intent V1) and the loan engine they lend through | [DebenLabs/gage-audit](https://github.com/DebenLabs/gage-audit): `audits/Gage-cash-security-review_2026-09-28.pdf` |

The report lists 10 findings, 6 Low and 4 Informational, all marked fixed. The review ran at commit `0638b91a3bcdfc417ae09f4baf23299d5110f85e`; the fixes were reviewed at `c4c6f7773449eb1f21a10faf6abe18ce852d326e`. Comments in `src/` cite its findings as `Pashov L-01` and so on.

Later code is not covered by that review: compare a contract with the reviewed commit to see what changed. Status of each contract: [docs.gage.cash/protocol/status](https://docs.gage.cash/protocol/status).
