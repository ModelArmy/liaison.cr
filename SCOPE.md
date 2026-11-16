# Scope

Outstanding work, tracked in two buckets. **Completed items are deleted, not
ticked** — this file is a worklist, not a changelog. It should grow through the
early phases and dissolve as the design settles.

- **MUST FIX** — blocks progress, or is cheap now and expensive later.
- **WILL FIX** — real, but deliberately not now.

Anything settled belongs in code comments or `DEVELOPMENT.md`; anything
outstanding belongs here, because nobody greps a codebase for open questions.

---

## MUST FIX

Vulnerabilities (V) first, then correctness (C). Labels are stable: a fixed
item is deleted, and the rest keep their numbers.

### V1. A tool's JSON Schema is spliced into the request unparsed

`Tool#parameters` is text, and every protocol's `ToolDeclaration#to_json`
writes it with `json.raw`. A schema that closes its own object can add keys to
the request: a scratch spec replaced `model` and `messages` on Chat
Completions, and `model` and `system` on Anthropic, under Crystal's
last-key-wins parsing. Which duplicate a server honours is the server's
choice, so the safe assumption is the attacker's. Schemas typically come from
MCP servers and configuration files, which is to say from someone else.
`Tool.new` also accepts text that is not JSON at all, which surfaces later as
a provider's 400.

Where: `src/liaison/options.cr`, `Tool#initialize`; the four
`wire/request.cr` files. Fix: parse in `Tool#initialize` and raise
`ArgumentError` unless the text is a JSON object. A valid object cannot break
out of its field, so the `json.raw` calls can stay. Reproduced by a scratch
spec; no spec covers it.

### V2. Exporters file opaque data under the protocol's vendor, not the deployment's

Mappers read `provider_metadata` under the narrowed `profile.metadata_key`;
exporters write it under the protocol's `METADATA_KEY` constant. On a
narrowed provider the two differ. Replaying the `ollama_responses_text`
transcript, Ollama's `encrypted_content` lands under `openai`. Handed to a
real OpenAI provider it maps `Exact` under `Strict` and is sent; handed back
to Ollama it reads as foreign. `docs/servers/OLLAMA.md` says it is stored
under `ollama`. Narrowing is enforced in one direction and bypassed in the
other, and the cost is one deployment's opaque payload sent to another
vendor.

Where: the four `export.cr` files, every `put_meta(METADATA_KEY, ...)`; the
adapters' `build`. Fix: construct each exporter with the narrowed key and
write under it. Changes request bodies for multi-turn Ollama Responses
transcripts that replay reasoning, so those need re-recording (local, free).
Reproduced by a scratch spec; no spec covers it.

### V3. Readers index JSON without checking it is an object

`JSON::Any#[]?(String)` raises a plain `Exception` on anything but a hash.
Every reader indexes first and asks later, so a body or frame of the wrong
shape escapes as an untyped exception instead of `MalformedResponseError`,
`StreamError` or `nil`. Ten cases reproduced, all raising: each protocol's
`export_reply` on a non-object body; a Chat Completions choice or `tool_calls`
entry that is not an object; a Chat Completions or Anthropic stream frame
that is an array or number; and `error_detail` on `{"error": "text"}` (a
string `error`, as some OpenAI-compatible servers send) or on a top-level
array (which the Gemini adapter's own comment says Gemini may return).

The `error_detail` case is the worst: it runs inside `Server#post` while
building a `TransportError`, so the status code is lost behind an unrelated
exception.

Where: `Wire::Response.from_json` and its helpers in all four protocols; the
assemblers' `absorb`; `Adapter#nested_error`. Fix: one shared helper that
returns the object or raises `MalformedResponseError`, called at each
reader's entry and wherever an array element is indexed; `nested_error`
returns `nil` instead. Reading the first element of a Gemini array of error
envelopes is a few lines more, with no recording to test it against; left
out unless wanted. Reproduced by a scratch spec; no spec covers it.

### V4. `Toolbox` sends an unexpected exception's message to the model

A `Function#call` that raises anything but `Function::Failure` is reported to
the model as `"the tool raised: #{error.message}"`. Exception messages carry
paths, SQL, hostnames and occasionally credentials, and the model is a third
party. `Failure` already exists for messages meant to be seen. Where:
`src/liaison/toolbox.cr`, `run`. Fix: send fixed text ("the tool failed")
and keep the detail in `exception`, which only `Archive` stores. Predicted by
reading.

### V5. Committed transcripts hold account and deployment identifiers

Credentials are filtered. Response headers are not: the Anthropic
organization id (14 transcripts), the Azure resource hostname and region (6),
and request ids (`request-id`, `x-request-id`, `apim-request-id`). The
repository is public.

**Open: whether this is acceptable.** If not, a Wiretap filter for these
headers on recording, and a scrub of the committed files. Response headers
play no part in matching, so scrubbing them is free. The Azure hostname is
also in the request URL, so scrubbing it means the Azure specs replay against
a placeholder server name. Checked by grep.

### V6. Unbounded and unchecked inputs, each minor

- **Azure `api_version`** goes into the query string unencoded
  (`adapters/azure/*.cr`, `path`). Caller-supplied, so low risk; encode it.
- **No size limits.** `Server` reads an error body whole, and `Sse.each_frame`
  reads a line with no bound, so a hostile or broken endpoint can exhaust
  memory. A cap on both, raising `TransportError`, is cheap.
- **`Server` holds one `HTTP::Client`**, which is unsafe for two fibers. Either
  document it as one-fiber-at-a-time or guard it.
- **`Archive.read` reads any role but `"user"` as assistant**, so a corrupt or
  hand-edited archive silently changes speaker. Belongs with *`Archive.read`
  raises more than `FormatError`* below, and is fixed by the same pass.

Predicted by reading.

### C1. The mid-tool-call rule is never applied

`Resolver` refuses foreign reasoning between a tool call and its result
(`Nesting::MidToolCall`), as the specification, the `DEVELOPMENT.md` diagram
and the checklist all say. No mapper passes `MidToolCall`, so the rule never
runs: Anthropic-signed reasoning in that position maps `Restructured` and is
sent to Gemini and Responses under `Strict`. Where: the four mappers'
reasoning paths; `Turns` already finds the unclosed turn.

**Open: enforce it, or drop it from the specification.** Enforcing it makes
some cross-provider handoffs of a tool loop refuse that currently go through.
No recording shows the rule is wrong, so the lean is to enforce. Reproduced by
a scratch spec.

### C2. A degraded tool exchange produces a request with half a pair

Under `Lenient` only, since `Degraded` exceeds the default `Compensating`.
But `Lenient` is what a caller picks to hand a tool-using session to a
stricter target, which is this shard's defining move. Three shapes:

- **Anthropic and Gemini drop a whole tool result** when one nested block
  degrades, text included. A result holding text and an audio clip with a
  transcript vanished entirely on Anthropic, its message was emptied and
  removed, and the `tool_use` went unanswered.
- **Chat Completions and Responses drop a degraded call and keep its
  result**, so a `role: "tool"` message answers a call that is not there.
- **Gemini maps the result of a dropped call as `unknown_function`**, since
  the `CallIdTable` holds no binding for it. A degraded call is any foreign
  call sent to a Gemini 3 model, which requires a signature.

Where: each mapper's `tool_call` / `tool_use` / `function_call` and its
tool-result method. Fix: degrade a call and its result together, rendering
both as text, on every protocol; within a kept result, degrade the nested
block and keep the rest. Whether each provider rejects an orphan or merely
confuses the model is unrecorded; the fix is right either way. Reproduced by
a scratch spec for the first two shapes; the third predicted by reading.

### C3. `audio/mpeg` is sent with format `mpeg`

Both OpenAI protocols derive `input_audio.format` from the media type's
subtype, so MP3 goes out as `"mpeg"`. OpenAI's documented values are `wav`
and `mp3`, from memory rather than a recording. Export reverses it to
`audio/mp3`, which is not a registered media type. Where: `format_of` in both
OpenAI mappers; `part_to_block` in both exporters. Fix: a two-way table, and
`RefusedError` for a media type outside it. Output reproduced; the spelling
needs a recording to confirm.

### C4. `Repair.repair!` deletes messages that annotations point at by index

`Annotation#message_index` is a position in `Session#messages`. `repair!`
removes the messages it empties, so every later annotation then points one
message too far, or past the end. Where: `src/liaison/mpsh/repair.cr`.
Fix: shift and drop annotations in the same pass. Reproduced by a scratch
spec.

### C5. `Client#send(max_tokens:)` is ignored on three protocols

`Client` fills `max_tokens` from the argument or the provider's default and
passes it to every adapter; only the Anthropic mapper reads it. A caller
capping a local model through `send` gets no cap and no annotation.
`Options#max_output_tokens` works everywhere. Where: `src/liaison/client.cr`,
`send`; the three other adapters. Fix: make `Options#max_output_tokens` the
one knob and keep Anthropic's required default inside its adapter, or apply
`max_tokens` as the fallback everywhere. Predicted by reading.

### C6. Four `Profile` fields drive nothing

`string_shorthand` is read nowhere. `alternation_required`,
`first_message_must_be_user` and `system_placement` are read only by
`Structural.required`, which nothing in `src/` calls and which predicts half
the structural adaptations: never `DropEmptyMessage`,
`DeferCompensationCarrier` or `CollapseAdjacentToolResults`. The mappers
hard-code the behaviour these fields describe, so the documented remedy for a
misbehaving provider, "fix its `Profile`", does nothing for them. Where:
`capability/profile.cr`, `capability/structural.cr`, the four
`capabilities.cr`. Fix: delete the four fields and `Structural.required`,
letting each mapper be the declaration; or make the mappers consult them.
The first is smaller and honest about what the code does. Checked by grep.

### C7. Small inconsistencies

- **Gemini's `CANNOT_DISABLE_THINKING` check is case-sensitive**
  (`includes?(model)`); Anthropic's and `Catalog`'s downcase. Fix: downcase.
- **Chat Completions keeps only the last reasoning block** of an assistant
  message: `map_assistant` assigns rather than appends. Fix: join them, as the
  field holds one string.

Predicted by reading.

### C8. `Provider` construction is duplicated, and the copies have drifted

`Provider.for` and `Provider.for_azure` repeat each other's logic, and
`Adapter#narrowed(model)` does two jobs, returning early from one. Two defects
follow:

- **A `reasoning_unit` override bypasses the signed-tool-call axis.**
  `narrowed(model)` returns early when an override is set, so it never calls
  `Catalog.narrow`, which applies both catalog axes. On a Gemini 3 model with
  an explicit unit, `tool_call_signature_required` is never switched on, so a
  foreign unsigned tool call maps `Exact` and draws the 400 the catalog entry
  exists to prevent.
- **`for_azure` accepts any `reasoning_unit` and ignores it.** `for` raises
  `ArgumentError` for a unit the protocol does not spell; `for_azure` has no
  such check. Both Azure protocols declare `Effort`, so a `Budget` override is
  accepted and then silently ignored, since `narrowed(model)` applies an
  override only to an `Either` unit.

Where: `src/liaison/provider.cr`; `src/liaison/adapters/adapter.cr`,
`narrowed(model)`. Fix: one construction path that `for_azure` delegates to,
with the guard; narrowing as two steps, catalog first and then the override
replacing only the unit axis. Predicted by reading.

---

## WILL FIX

Ordered by urgency, most urgent first.

### `Archive.read` raises more than `FormatError` on a malformed archive

`FormatError` covers a missing or unrecognised `format`, and unrecognised block
kinds, endings and outcomes. Anything else structurally wrong escapes as
whatever the JSON accessor raises: a missing `messages` key is a `KeyError`
(`root["messages"]`), a `messages` that is not an array a `TypeCastError`
(`.as_a`), and unparseable text a `JSON::ParseException`. Where:
`src/liaison/mpsh/archive.cr`, `read` and the `read_*` helpers.

It matters to an application loading archives from disk: a corrupt file
should be one rescuable error, not four. Likely fix: wrap the body of `read` and
re-raise the accessor exceptions as `FormatError` with the original as
`cause`. Predicted by reading; no spec covers it.

### `Profile` copies itself by hand

`with_metadata_key`, `with_reasoning_unit` and
`with_tool_call_signature_required` each re-list every field to build a copy.
A new field needs four edits, and a copy that misses one silently resets it to
its default on every narrowed provider. Where:
`src/liaison/capability/profile.cr`. Fix: one private `copy` taking named
overrides, which the three methods call; or make `Profile` a struct and use
Crystal's `copy_with`. Do it after C6, which may remove four of the fields.

### Fable's reasoning is model-bound, and replays as if it were not

Anthropic documents that thinking blocks from `claude-fable-5` and
`claude-mythos-5` are tied to the model that produced them, and that other
Claude models silently ignore them. `Resolver#own?` keys on the vendor
(`metadata_key` is `anthropic` for every Claude model), so a Fable session
continued on Opus or Haiku maps that reasoning `Exact`, and the model drops it
unannounced: the silent loss the capability model exists to report. Read from
documentation, not yet recorded. Where: `Resolver#own?` and
`Capability::Catalog`. Fix: decide whether the producing model belongs in the
reasoning block's provenance, which is a question about MPSH, not only this
protocol; then a probe, though "silently ignored" may show only as a reply
that does not use the earlier reasoning.

### A provider can ignore an exactly-mapped option, and nothing says so

`Options#tool_choice` maps `None` exactly on all four protocols. Gemini then
disregards it whenever the conversation already contains a tool call — four
recordings, two model generations three apart, this shard's own mapping ruled
out as a cause (`docs/protocols/GEMINI.md` has the table). Anthropic and the
OpenAI pair enforce it.

The reporting is the problem, not the mapping. `Report` comes back clean and
correct: nothing was restructured, degraded or refused, because nothing was —
the request said exactly what the caller asked it to say. The loss happens
after it leaves, and this shard has no vocabulary for that. Every `Outcome`
describes what became of the caller's *content*; none describes what became of
their *intent*.

That gap is the thing to close, and it is wider than `tool_choice`. Any
provider can accept a parameter and disregard it, so whatever is built here is
the pattern for the next one found.

**The hazard is concrete, which is why this is not merely tidy-mindedness.** A
caller ends a tool loop with `None`, receives calls anyway, and archives a
*completed* message holding unanswered calls — the shape `Repair.sendable?`
forbids, that `Repair` will not mend because `needed?` requires `ending.cut?`,
and that `docs/TOOL_EXECUTION.md` warns produces a session rejected on the next
request. Today nothing in the shard notices.

Four candidate answers, none obviously right:

1. **Check the reply.** If `None` was asked for and calls came back, record it.
   Protocol-agnostic, needs no `Profile` or `Catalog` axis, and stays correct
   the day Google fixes this — there is no vendor behaviour to model, only an
   observation to compare against a request. It also needs no account of
   *why*, which matters given the trigger below. The trap: it reports after
   the fact, so a caller learns on the turn it already paid for.
2. **Declare it on `Profile`.** A `tool_choice_enforced?` axis, false for
   Gemini, annotated before sending. This was the obvious candidate while the
   finding was "Gemini ignores `NONE`", and the evidence has since undermined
   it. The finding is *conditional*: `NONE` is honoured until the conversation
   contains a tool call. That is a fact about the protocol **and the session's
   contents**, and a `Profile` getter sees only the first. A boolean there
   must either over-warn — flagging the no-history case, which demonstrably
   works — or carry the defect in its own name,
   `tool_choice_unenforced_after_tool_call?`. When an axis has to describe a
   specific vendor bug to stay accurate, this is the wrong home for it:
   `Profile` describes what a protocol can *express*, and Gemini expresses
   this correctly.
3. **Document only**, and leave callers to check. Cheapest, and arguably
   principled — enforcing model behaviour is not a mapper's job. Against it:
   a silent non-guarantee is exactly what `Report` exists to prevent.
4. **Strip the unasked-for calls from the reply.** Delivers the guarantee, and
   is the only option that does. Rejected unless someone argues it back:
   dropping a block from a *reply* is a different act from adapting a request,
   it would discard a `thought_signature` that a later turn may need, and it
   hides the provider's real behaviour from the caller who most needs to see
   it.

Whichever wins, the sub-question stays: what is this called? Adding a fifth
`Outcome` means every exhaustive `case` over it changes, and the new value is
not like its siblings — they describe adaptations this shard performed, and
this one describes something a provider did. A separate channel on `Report`
may be the more honest shape, at the cost of a second thing for callers to
check.

### Mappers, assemblers and adapters repeat their leaf helpers

The protocols differ in structure, so a shared base mapper would be the wrong
abstraction. Their leaves do not differ:

- `materialize`, `byte_size` and `declarations` exist four times each, and
  `binary` four times, nearly identically.
- `decode` and `mid_stream` exist in all four assemblers.
- The adapters' `prepare`, `prepare_stream` and `build` repeat one shape four
  times.
- Chat Completions and Responses share `reasoning_effort`, `part_to_block`,
  `split_data_uri` and `format_of` line for line.

Fix: modules of plain functions for the leaves (payloads, OpenAI-family
parts, stream decoding), and `prepare` / `prepare_stream` written once on
`Adapter` over an abstract `build`. Behaviour-preserving, so the existing
specs are the check.

### The same four arguments travel through every mapper method

Most private mapper methods take `index` and `report`, and one or both of
`plan` and `pending`; 33 take five parameters or more. The adapter already
builds a mapper per request. Fix: hold the per-call state (report, plan,
pending carrier, and the index of the message being mapped) on the mapper or
in a small context object, so signatures shrink to the block being rendered.

**Open: whether to do this, or stop at the leaf helpers above.** It touches
every mapper method.

### Tuples stand in for a type in the reasoning mappers

Anthropic's `reasoning` returns `{Int32?, String?, Bool}`, Gemini's
`{Int32?, String?}`, with "at most one is set" in a comment. `Reasoning::Request`
already shows the fix: a closed union (`Budget | Effort | Disabled`, or
`Nil`), which makes the invariant the compiler's and lets the comment go.
Where: both mappers' `reasoning`, and the `Wire::Request` fields they feed.

### Long names repeated where a short one would read better

`Capability::ReasoningControl::Rendering::` appears 16 times;
`Capability::Structural.outcome(Capability::Structural::Adaptation::...)` 7
times; the `.as(MPSH::Block?)` widening cast 12 times, several with the same
explanatory comment. Fix: local aliases or a short helper per case (a
`record_adaptation(:move_system_prompt, detail)` on the report, a `blocks`
helper that widens). Cosmetic, but these are the lines a reader trips on.

### Dead code

- `MalformedResponseError` is declared twice, in two identical
  `module Liaison::Protocol` blocks in `src/liaison/protocol/errors.cr`.
  Crystal reads the second as a reopening, so an edit to one copy alone would
  be silently overridden or duplicated. Delete the first.
- The Chat Completions mapper's `refusal_text` takes a `parts` it never uses.
- Three `COMPENSATION_PLACEHOLDER` aliases of
  `Capability::Carrier::PLACEHOLDER`, one per protocol. Use the original.

### Comments carrying what the code could say

Comments are about 21% of non-blank source lines. Most are API
documentation and earn their place. The ones to remove are those that explain
an invariant the code could enforce (the tuple contracts above) or a long name
(the widening casts). Do this with those two items rather than as a separate
sweep.

### `HANDOFF.md` has outgrown its purpose

It describes itself as deliberately short and runs to 531 lines, much of it
the history of how things were found. `DEVELOPMENT.md`'s own rule sends
history to commits and settled decisions to code comments or
`DEVELOPMENT.md`. Fix: keep State, Next and pointers; move anything still
true elsewhere; delete the rest.

### `ToolChoice::Required` needs a catalog axis and a conflict rule

`Options#tool_choice` ships with `Auto` and `None`, which every protocol
supports and agrees about. The third value — Anthropic's `any`, OpenAI's
`required`, Gemini's `ANY` — is left out, and the reason is that it is not the
one-line addition it appears to be. Two hazards, both attached to this value
alone:

- **It is model-gated on Anthropic.** Where forced tool use is unsupported,
  `any` and `tool` fail while `auto` and `none` keep working. That is a
  `Capability::Catalog` axis, and *A model catalog* below already says a third
  axis must argue its own default rather than inherit either existing one —
  the two present axes reach the same optimistic default by opposite
  reasoning, so neither generalises to this.
- **It conflicts with an option this shard already has.** Forced tool use is
  incompatible with extended thinking on Anthropic, so `Required` plus a
  thinking budget is a request the mapper could build and the endpoint would
  reject. `Options` already refuses one combination of its own fields —
  `tool_choice` with no tools — but that rule is protocol-independent, so it
  can live in the constructor. This one holds on one protocol only, so where
  it lives is worth deciding rather than assuming: a conflict between two
  request options is neither a `Profile` fact nor a block question.

Neither hazard touches `Auto` or `None`, which is why they shipped without
waiting for this.

Also still out, and more cheaply: the fourth form, naming a specific tool the
model must call. It carries an argument, so adopting it turns `ToolChoice` from
an enum into a closed union and changes every caller's `case`. Additive in
meaning, breaking in shape. No caller in view.

### Retention governs replay, not display and not storage

Surfaced settling a streaming question, and recorded because the assumption is
natural and wrong. `Capability::ReasoningRetention` is applied in exactly one
place — `Capability::Retention.plan`, called from the four `Mapper#map`
implementations. No exporter consults it. So under `None`, a reply's
`ReasoningBlock` is still exported into the `MPSH::Message` and still handed to
the caller, so anything archiving that message archives the reasoning with it.
Only the *next* request omits it.

That is the correct behaviour and the enum's own comment already says so — it
is a playback preference, not a capability. What is missing is anything that
answers the other two questions someone might reasonably think it answers:

- **Display.** Whether reasoning is shown live. Belongs entirely to the
  consumer; the sane default there is off.
- **Storage.** Whether reasoning is retained in the session and archive at all.
  Nothing offers this. A caller who wants reasoning never persisted has to
  strip it from the reply themselves before `session << reply`.

Whether the third one deserves a control is genuinely open, and there is no
evidence yet that anyone wants it. Do not reach for `ReasoningRetention` when
they do: conflating the three axes is the exact failure its comment warns
against, and a fourth `None`-like member that silently meant something else on
each axis would be worse than a new type.

### `max_tokens` vs `max_completion_tokens` is per-deployment, not yet per-model

Confirmed live: `gpt5.4mini` on Azure rejects `max_tokens` outright and wants
`max_completion_tokens`, OpenAI's replacement field for the reasoning-model
line. Ollama's Chat Completions-compatible endpoint has the opposite problem —
`max_completion_tokens` support has been an open, unresolved request against
it for over a year, so defaulting to the new spelling would silently stop
capping output there rather than fail loudly.

Handled for now as an explicit, per-adapter override —
`Wire::MaxTokensField`, threaded through `Provider.for`/`.for_azure` the same
way `reasoning_unit` already is — defaulting to the old spelling everywhere,
stated explicitly for a deployment known to need the new one. Not a
`Capability::Catalog` axis: Catalog matches on model string, and this
shard has no live coverage yet of plain OpenAI direct, only Azure and
Ollama's emulation of the protocol. Building an exact-match list now would be
guessing ahead of evidence this shard doesn't have.

Worth revisiting once there's a second data point beyond Azure — a live
OpenAI-direct spec, or a second Azure deployment on an older, non-reasoning
model that still wants `max_tokens`. At that point this becomes the same
shape as the reasoning-unit catalog: an exact-match table plus the same
deployment-level override for names that carry no model identity.

### Reasoning controls: the unit is keyed on the model

`Profile` gained `reasoning_unit`, `Capability::Catalog` resolves `Either` per
model — see each protocol's own `docs/protocols/*.md` for the spelling.
What remains open is only what a live call can settle:

- **Rungs are model-dependent on the OpenAI protocols too.** `xhigh` and `max`
  serialize happily and may still be rejected by the model behind the endpoint.
  A protocol-level declaration cannot know, and a per-model rung list is a
  catalog axis nobody has yet needed. Wait for a rejection.
- **No budget clamp on Gemini.** Anthropic documents that the budget must sit
  below `max_tokens`; Gemini documents no such relationship, so none is
  invented. Revisit the first time a live call disagrees.

### A model catalog, keyed independently of protocol

`Capability::Catalog` resolves an ambiguous reasoning unit per model — see
its own doc comment for the shape and the reasoning behind the optimistic
default. Still open, and the reason this stays in WILL FIX:

- Should the catalog become a layer, or stay a lookup returning a narrowed
  `Profile`? The lookup is still right on two axes: `SIGNED_TOOL_CALLS`
  arrived exactly as this section predicted — a second axis on the same
  entry, not a second mechanism — and needed no structural change to land.
  The one thing it did change is that "why the default is optimistic" is now
  a per-axis argument rather than a catalog-wide one, and the two axes reach
  the same default by opposite reasoning. A third axis should state its own
  rather than inherit either.
- `ReasoningRetention::CompletedTurns` exists for a requirement keyed on model
  and is still applied by hand. Declared media support has the same problem in
  miniature — both OpenAI profiles list audio media types, but audio support is
  model-gated in practice.
- Per-model *rung* support, if a rejection ever demands it. A second axis on
  the same entry, not a second mechanism.
- **"Cannot turn thinking off" is a model fact held in two protocol lists.**
  `CANNOT_DISABLE_THINKING` exists on Gemini (`gemini-3.1-pro-preview`) and on
  Anthropic (`claude-opus-5-5`), each with its mapper substituting the lowest
  rung. The fact belongs to the model; only the substitute's spelling belongs
  to the protocol. The move is a `Catalog` axis narrowing a `Profile` field,
  with `ReasoningControl.resolve` turning `Off` into the lowest rung for every
  protocol. Kept as two lists until a third model or protocol needs one, since
  the move touches working Gemini code for one shared line of logic.

### A localizable content synthesizer

Mappers insert two kinds of text, and conflating them would break export.

&nbsp;     |Markers                                             |Glue                                    
-----------|----------------------------------------------------|----------------------------------------
Examples   |`COMPENSATION_PLACEHOLDER`, `FIRST_USER_PLACEHOLDER`|"Result of a provider-run web_search:"  
Read by    |Our own exporter, structurally                      |The model                               
Must be    |Byte-identical in both directions                   |Idiomatic in the conversation's language
Localizable|**Never**                                           |Yes                                     

Markers are matched exactly on export, so a session mapped under one locale and
exported under another would fail to recognise its own scaffolding. They stay
constants, and the reason is recorded beside them.

Glue is read by the model and should be in the conversation's language — which
is *not* the user's interface locale: someone with a French UI may be talking to
the model in Spanish.

Shape: a method-per-case interface (`combine_tool_call_with_response(...)`)
rather than a translation table, so an implementation can reorder a sentence
instead of substituting words. English implementation first.

Two constraints, both load-bearing:

- **It must be a pure function.** Mapping determinism and prefix stability are
  asserted in `spec/conformance/determinism_spec.cr` and are the precondition
  for prefix caching. A sidecar model generating glue per call breaks both. If
  dynamic synthesis is wanted, its output must be generated once and pinned —
  `provider_metadata` on the block that needed it is the natural home — and the
  interface should permit that without changing callers.
- **Locale is supplied, not detected.** Inferring it is a guess that degrades in
  mixed-language sessions. Default English.

Build when the Gemini mapper needs it, so it has two consumers rather than one.

### Server-executed tools degrade without their framing

When a provider-run tool has no equivalent on the target, the result content
survives as conversation and the tool framing does not. That is the right
choice — synthesizing a phantom `tool_call` would advertise a tool the target
does not have, and may prompt it to request one — but the current degradation
drops the framing entirely.

Bare result content loses the fact that a lookup occurred, which occasionally
matters. A short lead-in restores it as prose. That lead-in is **glue**, so it
waits on the synthesizer above.

Explicitly not attempted: re-expressing one vendor's server tool as another's.
Anthropic's web search and Gemini's code execution have rough counterparts, but
they take different parameters and return different shapes, so the mapping
cannot be right by construction. It is the same class of problem as the model
catalog, one layer up.
