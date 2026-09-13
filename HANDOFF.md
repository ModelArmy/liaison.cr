# Handoff

For starting a fresh session on this shard. Deliberately short: almost
everything worth knowing is already in the repository, and this file points
rather than restates.

## Read in this order

Document                    |Why                                                                            
----------------------------|-------------------------------------------------------------------------------
`docs/MPSH_SPECIFICATION.md`|Authoritative. §8a records what the checkpoint established and what it did not 
`SCOPE.md`                  |The worklist. Every open question, each with the trap that makes it awkward    
`DEVELOPMENT.md`            |Layering, conventions, how an agent uses the shard, how to add a protocol      
`docs/protocols/*.md`       |One per protocol: declared capabilities, limits, the bugs each produced        
`docs/servers/*.md`         |One per server: what it serves, where it diverges, what a green run misses     
`README.md`                 |The front door: what the shard is for, and the handoff in twenty lines         

Where this file and `docs/MPSH_SPECIFICATION.md` disagree, the specification
wins.

## State

Phase 3 is complete: **the live handoff works.** Four protocols — Chat
Completions, Responses, Anthropic, Gemini — each with a mapper, an exporter, a
response reader, and a wire request that can declare tools and cap output.
Zero runtime dependencies; `wiretap` is development-only.

Three of the four protocols have been exercised against Ollama's compatible
port — Chat Completions, Responses, and an Anthropic-compatible endpoint from
one port. `spec/live/ollama_spec.cr` records a session answered by one
protocol and continued on another, including a tool call minted on one and
replayed on the next. But a compatibility port proves the shape is accepted,
not that the vendor whose protocol it imitates would accept it. The real
Anthropic endpoint has now also been called directly, and settled two things
Ollama structurally could not: a `thinking` block with no signature is a
genuine 400 (`spec/transcripts/anthropic_thinking_no_signature.json`), and a
real signature genuinely replays on the next turn while the budget path and
its 1,024-token floor are accepted as documented
(`spec/transcripts/anthropic_thinking_signature_replay.json`). Detail in
`docs/protocols/ANTHROPIC.md`. All transcripts are committed under
`spec/transcripts/` and replay offline, so the suite needs no server.

Request options are complete: tool declarations, output caps and reasoning
controls, the last of which introduced `Capability::Catalog` — the fourth
identity. It now carries **two axes**: the reasoning unit two protocols spell
differently and reject being handed both, and whether a model authenticates
its own tool calls. Both narrow the same `Profile` per call. Read *A model
catalog* in `SCOPE.md` before adding a third — the two reach the same
optimistic default by *opposite* arguments, and neither generalises.

**Gemini is now executed, the last of the four.** Ollama never served it, so
unlike Anthropic this had no compatibility port to have already exercised the
wire shape — first contact and the falsifying tests happened in the same pass.
Found and fixed along the way: Gemini 3 requires a `thoughtSignature` on
`functionCall` parts, which `liaison` had nowhere to carry, and
`gemini-3.1-pro-preview` actively rejects a zero thinking budget rather than
silently ignoring it, both now handled
(`spec/live/gemini_spec.cr`, `docs/protocols/GEMINI.md`). Confirmed and closed:
the reasoning-off budget genuinely disables thinking on Flash, and
`reasoning_signature_required` correctly stays `false` here — Anthropic's fix
does not generalize to this protocol's plain-text reasoning, only to its tool
calls. **Now closed too:** a `ToolCallBlock` handed to this protocol from
another has no signature to offer, and `Resolver` checks for that ahead of
`own?`, reporting `Degraded` rather than sending a request that cannot
succeed. Keyed on the model via `Catalog`, not declared on the protocol,
because the requirement arrived with Gemini 3 and the 2.5 series lacks it —
`docs/protocols/GEMINI.md` records why the protocol-wide version was written
first and rejected.

Recording practice, and why re-recording is more disruptive than it looks:
*Live specs* in `DEVELOPMENT.md`.

**Azure OpenAI is now live too, and it amended the design as expected.**
`Adapter` assumed path and auth were protocol facts; Azure proved them
protocol-*plus*-deployment facts — `Provider.for_azure`,
`AzureChatCompletionsAdapter`, `AzureResponsesAdapter`. The two protocols
disagree with each other on where the deployment lives (path segment for Chat
Completions, body-only for Responses) badly enough that Microsoft's own
documentation disagreed with itself; settled against a live deployment's own
portal rather than guessed. First contact also found a live gap unrelated to
the amendment itself: a reasoning-capable deployment rejects `max_tokens`
outright and wants `max_completion_tokens`, handled as an explicit
per-deployment override (`Wire::MaxTokensField`) rather than a model catalog,
since Azure deployment names carry no model identity a catalog could match
against — same shape as `reasoning_unit`'s existing override, and the same
justification. Detail in `docs/servers/AZURE.md` and
`docs/protocols/CHAT_COMPLETIONS.md`'s own *Live finding* sections.

**Carrier deferral is now extracted**, ahead of a fifth protocol as its own
entry asked. The rule — buffer lifted content, flush before anything that is
not a tool result, recognise the carrier again on the way back — lived in three
mappers and three exporters, written differently each time and wrong once. It
is now `Capability::Carrier` (`src/liaison/capability/carrier.cr`), generic over
the wire part type so it cannot know what a protocol is, with the marker as one
constant rather than three that had to stay byte-identical forever. A protocol
keeps only the message shape it spells a carrier with, plus any precondition of
its own, which is why `carrier?` takes an `eligible` flag rather than letting
callers guard ahead of it: both preconditions sat *below* the synthetic check
and hoisting them would have changed the answer. Unit-tested directly for the
first time (`spec/capability/carrier_spec.cr`) — the old arrangement could only
test each copy through its own protocol's fixtures, which is exactly how one
copy stayed wrong. That spec immediately earned itself: it caught an
inherited infelicity in `absorb`, which counted markers but filled the first
one still open, so a part the target could not express left the surviving
marker trailing at the end of the result instead of standing where it belonged.
Placement is positional now, and `SCOPE.md` is one item shorter than it was
rather than level.

**Two things now exist beyond the live protocol layer itself.**
`MPSH::Archive` (`src/liaison/mpsh/archive.cr`) round-trips a `Session` to
JSON and back — the piece the whole portable-history pitch was missing,
since nothing previously turned a `Session` into anything that could
survive past one process. Tested against the full MPSH fixture set through
`Conformance.compare`, zero divergence required (`spec/mpsh/archive_spec.cr`)
— a stricter bar than any protocol gets, since this isn't a capability
adaptation and has no matrix to excuse a difference.

**The CLI has left this repository.** It was built here — verbs, config file,
session storage, a spinner, a streamed turn — as the most direct demonstration
of the handoff, and it moved out to its own project when its next feature, tool
execution over a sandboxed filesystem, needed a runtime dependency this shard
deliberately does not have. Nothing here depends on it and nothing here should
name it: applications depend on `liaison`, not the reverse.

What that cost and what it did not: the CLI specs were this shard's only
full-stack coverage, and the only place a session was ever written to a disk and
picked back up — which is the product claim. `spec/end_to_end/` was written
first, to hold exactly that, and stayed. See *Next*.

Two decisions the CLI settled are still live here because they were never really
the CLI's. `Capability::Retention`'s parked question — whether a model catalog
should exist for reasoning preferences — is answered no, because those are soft
preferences read off a model card rather than hard protocol facts, so they
belong in an application's configuration where adding a model needs no release
of this shard. And the display question retention does *not* answer is the
consumer's: `SCOPE.md`'s *Retention governs replay, not display and not storage*.

## The live layer

Built and described in `DEVELOPMENT.md` — *Layering*, *Three identities, kept
apart*, and *Live specs*. The short version: `Server` is a deployment,
`Provider` is a server speaking one protocol plus its vendor claim, `Adapter`
holds the only endpoint knowledge, `Client#send` performs one exchange and
returns `(MPSH::Message, Capability::Report)`.

The one rule worth repeating here because breaking it is silent: vendor
narrowing is **one-directional**. A provider may declare that a deployment
honours *less* than its protocol allows, never more.

## Next

**Tool execution's library half is built, and the library half is all this
shard owes.** What an application declares and what it runs is its question, not
this one's — `docs/TOOL_EXECUTION.md`'s *What this does not answer* says so, and
says the one thing worth knowing before answering it: declaring and executing
are one decision, not two.

`Liaison::Function` is a declaration plus its handler, `Liaison::Toolbox` holds a collection and is used at both ends
of a turn — `#tools` out, `#dispatch` back, `nil` from `#dispatch` as the loop's
exit condition. `docs/TOOL_EXECUTION.md` records the shape and the seven
decisions behind it. Four are worth knowing before touching it: a tool result is
`Array(MPSH::Block)` rather than a new type, because `ToolResultBlock#content`
already is one; arguments arrive as a parsed `MPSH::Object` and `MPSH::Value` is
a real union, not a `JSON::Any`; tools stay in `Options` and never in `Session`,
because a `Function` is Crystal code and a portable archive cannot express one;
and `#dispatch` repairs its own argument, so `docs/STREAMING_DESIGN.md`'s
*Events are not an account of a cut turn* cannot be got wrong by a caller who
has not read it.

One asymmetry inside it is easy to get backwards. `ToolResultBlock#is_error` is
carried by the mappers; `#exception` is written by `Archive` and read back, and
nowhere else. So a tool that *reports* failure sets only `is_error`, and a tool
that raises unexpectedly must set both — otherwise it crashes and the model is
never told.

`SCOPE.md`'s remaining entries all predate the streaming work.

**`spec/end_to_end/` exists because the CLI left.** Those specs were this
shard's only full-stack coverage — and the only place a session
was ever written to a disk and picked back up, which is the product claim. Three
files now cover that at the library level: the handoff across a file, a streamed
turn archived and resumed, and a `Toolbox` exchange accepted by a second
protocol. All against local Ollama, all free to re-record.

One thing they taught, which cost five red examples to learn: Ollama reasons on
every endpoint and cannot mint an Anthropic thought signature, so any handoff
into Anthropic carrying a reasoning block degrades and `Compensating` refuses
it. The four handoff examples pass `Reasoning::Off`, because retention is a
different axis from portability; the fifth asserts the loss deliberately, under
both policies.

**`SCOPE.md`'s `MUST FIX` is empty.** Interrupted-turn repair, the last entry
in it, is built, and the argument that used to live there now lives in
`docs/MPSH_SPECIFICATION.md` §3a — where it belongs, being a statement about
the format rather than an open question.

`MPSH::Ending` is a settable field on `MPSH::Message`: `Complete`, `Truncated`,
`Stopped`, `Interrupted`. The four exporters normalise their own stop reason
onto it and keep the verbatim copy; `Client` sets the two facts only it knows.
`MPSH::Repair` is pure MPSH — drop the calls, keep any text — with the
invariant expressed as `Repair.sendable?` rather than described.

Three things about it are worth knowing before touching it, because each was
checked and none is obvious:

- **The field is outside round-trip identity, deliberately**, on
  `text_fallback`'s terms. No protocol has a *request*-side field meaning "this
  message was cut short", so `Conformance.compare` does not check it and says
  so in writing. Adding it there would report a permanent divergence reading as
  a mapper bug.
- **Which means the archive's own gate does not reach it.** `archive_spec.cr`
  claims zero divergence for every fixture and enforces it through
  `Conformance.compare` — which walks only what a wire can carry, and is
  equally silent on `Provenance` and annotations. `Archive` could stop writing
  `ending` entirely and every fixture would still pass. Covered by explicit
  examples instead, the same way annotations already were.
- **`Client` no longer raises on a cut stream.** It returns the partial reply
  carrying `Ending::Interrupted`; the raise was a placeholder chosen when there
  was nowhere to record *why* a reply was partial. An in-band error frame still
  raises `Protocol::StreamError` from the assembler that read it — that is a
  failure the server described, this is one it never mentioned.

**`Ending::Interrupted` is now covered end to end**
(`spec/streaming/interrupted_spec.cr`), which was the last gap the repair work
left. No server sends a truncated stream on request, so the two fixtures are
recorded transcripts cut by hand — the one sanctioned exception to *record,
never hand-write*, argued in `DEVELOPMENT.md`: the frames are recorded and only
the cut is ours. Replaying one needed nothing from Wiretap, since both
responses are chunked with no `Content-Length` and a shorter body is just a
shorter body.

The pair also earns its keep beyond the field it covers. Cut at the same point
— immediately after a tool call finished arriving — Anthropic carries the call
into the reply because `content_block_stop` vouched for it, and Chat
Completions refuses it because nothing did, even though its arguments parse.
Two different messages, identical sessions after `Repair`. That divergence is
what `docs/STREAMING_DESIGN.md`'s *Events are not an account of a cut turn*
rests on, and it had no test until now.

Streaming was built **one protocol at a time** — read
`docs/STREAMING_DESIGN.md` before touching it. The short version: frames
assemble into each protocol's own `Wire::Response` and then take the *existing*
`export_reply(Wire::Response)`, so there is exactly one translation path and a
streamed reply is the same `MPSH::Message` as a non-streamed one by
construction.

**All four slices are done. Streaming is built for the library.** What
exists now:

- `Liaison::Streaming` — `Sse` framing shared by all four protocols, a closed
  five-variant `Event` union, `Turn` (the cooperative stop handle), and the
  abstract `Assembler`.
- `Server#stream`, and `Protocol::StreamError` beside `MalformedResponseError`.
- `Client#send` with a second overload taking `|event, turn|`. **Passing a
  block is the request to stream**; there is no flag. Adapters opt in by
  overriding `Adapter#prepare_stream`, which returns `nil` by default, and
  `Report#streamed` says which way a turn actually went.
- An assembler for each of the four protocols — `Responses`, `Gemini`,
  `Anthropic`, `ChatCompletions` — each with offline and live specs.
- `Adapter#stream_path`, defaulting to `path`. Gemini is the only protocol
  where streaming is a different method on the URL rather than a flag in the
  body, and `alt=sse` is required or the endpoint streams a chunked JSON array
  instead of server-sent events.

**The rule every remaining assembler follows: never stitch anything whose
partial form is invalid.** Text concatenates — a prefix is a legitimate short
answer. A tool call does not: half an arguments blob cannot be dispatched, so a
call still arriving when the stream ended must not appear in the reply.

Both halves of that were learned rather than designed. Responses first called
for keeping only the terminal frame, which is trivial and wrong — the whole
reply lives in that frame, so `Turn#stop` would return nothing. Gemini then
broke the replacement wording (*assemble from complete units*) by emitting no
finished units at all. `docs/STREAMING_DESIGN.md` records both corrections;
expect Anthropic and Chat Completions to test the rule again rather than to
fit it quietly.

**Streaming is proved against vendors, not only against Ollama.** That turned
out to matter: recording against Azure and Anthropic found a bug Ollama had
been hiding — every `Usage.parse` mishandled a `"usage": null` chunk, which
Azure and OpenAI send and Ollama omits — and confirmed the one thing only a
vendor could confirm, that a streamed Anthropic `signature_delta` survives and
is accepted when replayed. The general lesson is in `docs/servers/OLLAMA.md`:
this server is *more* forgiving than the endpoints it imitates, and offline
fixtures cut from its transcripts inherit that blind spot. Gemini's streamed
`thoughtSignature` is now proven on replay too (`gemini_stream_resumed`), which
was the last live gap: the signature rides on the `functionCall` part, and
`Resolver` reports `Degraded` on a call that lost one, so a damaged signature
raises rather than passing quietly. **No live gaps remain in streaming.**

**Interrupted-turn repair is built on top of it** — see *Next* above. Two
things the streaming build had already settled did most of the work: a stopped
turn and a cut turn are indistinguishable to an assembler, so the fact has to
be set by the layer that knows; and every assembler already refuses to emit a
tool call it cannot vouch for, so "drop the calls, keep any text" was already
true for a cut stream in all four protocols before repair existed.

Streaming is built. Tool execution's library half sits behind it, and is no
longer blocked by anything.

**How the rule was arrived at matters more than the rule.** It was rewritten
twice under contact — first from "keep the terminal frame", then from
"assemble from complete units" — and each rewrite came from a protocol
refusing to fit. Expect the same of anything added later rather than assuming
the current phrasing is final.

**Two traps worth knowing before touching `Server#stream`.** Nothing within its
reach may `yield`: the block reaches `HTTP::Client#exec(request, &)`, which
Wiretap redefines with a *captured* block, and `yield` is illegal inside one.
Relatedly, it calls `exec` directly rather than `post` — `post`'s block form
routes through a stdlib overload that yields, which cannot compile at all while
Wiretap is loaded. That is a latent Wiretap bug affecting any consumer calling
a verb with a block; it has not been reported upstream yet.

Wiretap does record and replay SSE, but it buffers the whole body before
handing it on, so **no spec here exercises incremental arrival** — only frame
vocabulary and assembly.

### On Ollama

What it serves, where it diverges, and what a green run there does *not* prove:
`docs/servers/OLLAMA.md`. Read it before treating any live green as having
closed an open question — Ollama has no signature to validate, which is
exactly why the narrowing default needed a real Anthropic recording rather
than a green run here to settle it. See `docs/protocols/ANTHROPIC.md`.

## How to work on this

- **Read declarations, not fixture names.** Twice, assertions were written from
  the general story rather than from a protocol's declared `Profile`, and were
  wrong both times. `unsupported_media_type` is *exact* on Anthropic, because
  WEBP is accepted there.
- **`Restructured` is not a bug waiting to be found.** Twice while getting
  Azure live, a `report.worst.should eq Exact` failed and looked like a new
  protocol gap — it was the test both times, not the mapper. Chat Completions
  and Responses both report `Restructured` on *any* session carrying a system
  prompt, unconditionally, by design: MPSH holds the prompt as a session
  field, and turning it into any wire form is a restructuring of MPSH's own
  shape regardless of whether the destination protocol calls that placement
  native. Pinned already in `spec/conformance/layer_spec.cr`; check there —
  or the protocol's own doc — before assuming a Restructured result is new
  information.
- **A test's own sandboxing can break the thing it's testing around it.**
  Two of the departed CLI's specs `Dir.cd`'d into a temp directory to sandbox
  their own filesystem resolution, and silently broke Wiretap's
  own relative transcript path doing it — Wiretap resolves that path against
  the real process CWD too. Every spec passed, because the live call to
  Ollama still succeeded; the recordings just never landed anywhere real,
  and the sandbox's own cleanup deleted whatever had been written into it
  before anyone noticed. Fixed by giving the code under test an explicit
  env-var override instead of moving the process's CWD at all: sandbox exactly
  what the code under test reads,
  never anything downstream of it that happens to read the same ambient
  state.
- **A guard at the right seam still needs a non-raising twin.** Session id
  validation went into `Sessions.path_for` — correct, since an id becomes
  dangerous exactly when it becomes a path, and no future verb can forget it
  there. But `list` enumerates the folder through the same method, so one
  `.DS_Store` took the whole listing down on first real use. A validator for
  *input* and a predicate for *enumeration* are different questions;
  `validate_id` and `valid_id?` are both needed.
- **Crystal is not Ruby, in three places this shard has already hit.** `out` is
  a reserved word and cannot name a property or a local. There is no trailing
  `while` modifier, only trailing `if`/`unless`. And a variable captured by a
  block — an `OptionParser` handler, typically — will not narrow out of `T?`
  however it is tested; copy it to a fresh local first.
- **Corrections cluster in the capability model, not the format.** Three came
  from declaring profiles and round-tripping fixtures; all three changed the
  capability model. Gemini, the protocol most likely to break MPSH, changed only
  mapper code.
- **A green suite is narrower than it looks.** Compilation proves types line up.
  Structural conformance proves shapes. Neither says anything about request-time
  behaviour.
- **A fixture written by the same hand as the code tests the hand, not the
  wire.** One recording found a bug that hundreds of green offline examples
  could not. See *Live specs* in `DEVELOPMENT.md` for the rules that follow
  from it.
- **A settled "won't do" is a decision**, not an oversight to helpfully
  correct. `DEVELOPMENT.md`'s "No `UNSUPPORTED.md`" and this file's *Deferred,
  and staying deferred*, below, are both this.
- Diagrams are Mermaid, fenced inline in Markdown so they render on GitHub.
- Nothing under `mpsh/` may know that HTTP or any provider exists, and no
  canonical type may serialize into a request body.

## Deferred, and staying deferred

Session tree, branching, scatter/gather, provider bindings, stateful handles,
streaming, tool execution, prompt caching, compaction. See
`docs/IMPLEMENTATION_PLAN.md` §7 and `docs/PSR_BRANCHING_AND_SCATTER_GATHER.md`,
which carries a deferred-status banner for exactly this reason.
