# GapTrap driver fixtures

Test data for `tests/phase21-gaptrap-driver.test.sh`. Nothing here talks to a network.

## Files

- `*.http`: one recorded reply each. Line 1 is the HTTP status, the rest is the body. This is the
  shape the driver's `ACFW_GAPTRAP_TRANSPORT` seam expects. A file that holds only `exit:<n>` makes
  the seam exit with `n` and print nothing, a transport failure (`conn-refused.http` is curl's 7,
  a request that never left).
- `fake-transport`: the seam. It reads one JSON-RPC request, logs it, and replays a reply picked by
  slot name and call count (see its header). It logs before any delay, so a run killed mid-request
  counts as having reached GapTrap.
- `fake-curl`: stands in for `curl` on PATH, so the suite can exercise the driver's real transport
  and check with `ps` that the API key is in no process's arguments.
- `plan.md`, `plan2.md`: the plan and a revision of it. Both put em dashes before the text a gap
  quotes, so a line number computed from byte offsets instead of codepoint offsets comes out wrong.
  In `plan2.md` the quoted text also changes case and wraps a line.
- `make-fixtures.sh`: regenerates every `*.http` file. Run it after changing a shape, then rerun the
  suite.

The `list_specs` replies that find a spec after a lost `create_spec` reply are not stored here. The
suite builds them at run time, because the match depends on the attempt tag the driver chose and on
a `createdAt` close to now.

## Where the shapes come from

The envelopes are synthetic, shaped after the replies GapTrap's MCP endpoint sends:

- A successful tool call wraps its payload as one JSON text block. A tool error sets
  `isError: true` with `{error: {code, message}}`. 401 and 403 `plan_required` are HTTP-level JSON
  bodies, not JSON-RPC.
- MCP SDK 1.29 `mcp.js`: an unknown tool, or an uncaught throw inside a tool, comes back as
  `isError` with plain text, not JSON (`unknown-tool.http`, `create-throw.http`).
- The `create_spec`, `get_analysis_status`, `get_analysis_report` and `list_specs` result fields
  (`list_specs` carries `filename` and `createdAt` in both scopes, newest first), and the
  `quota_exceeded`, `spec_too_large` and `NOT_FOUND` codes. `create_spec` deletes the spec before
  it answers with any of its own codes.
- The report: `verdict`, `contractStatus`, and snake_case gap fields such as `source_offset` and
  `resolution_questions`.
- The write-2 card for an empty required section (`<Title> is empty`, extraction text
  `<Title> (section is empty)`, offset `[0, 0]`, a section-keyed `gap_id`), here for the built-in
  template's `functional_acceptance` section and its `missing_question`.

The values are synthetic. Gap offsets are Python codepoint indices into `plan.md` and `plan2.md`,
computed from the files themselves. One gap in `report-rerun-go.http` uses camelCase keys on purpose,
because the report's key casing is mixed.

`get_spec` and `list_answers` are optional. The driver probes `tools/list` for them and turns pull
and answers off when they are absent. Their fixtures use the shapes
`{content, format, parentSpecId, contentSha256, webUrl}` and
`{answers: [{gapId, questionIndex, question, answerText}]}`.
