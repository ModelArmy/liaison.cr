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

### The unsigned-`thinking` 400 has no transcript

`spec/transcripts/anthropic_thinking_no_signature.json` is cited by four places
— `HANDOFF.md`, `docs/protocols/ANTHROPIC.md`, `spec/live/anthropic_spec.cr`
and `spec/conformance/anthropic_spec.cr` — as the recorded evidence that
Anthropic's schema *requires* `thinking.signature` rather than merely
validating it. The file was never committed: `git log --all` on the path is
empty, and the working tree and the remote hold the same 50 transcripts.

The claim it backs is load-bearing. `Profile#reasoning_signature_required?` is
true for exactly one protocol, and `Resolver` checks it *ahead* of `own?`,
overriding the "empty metadata is portable" default that is right everywhere
else. That inversion is justified by this 400 and by nothing else. The
behaviour is guarded offline at `spec/conformance/anthropic_spec.cr`
("declared divergences"); what is missing is the observation the guard was
derived from.

**Why it went missing is the part to fix.** Nothing replays it — deliberately,
since the fix means the client no longer builds that request — so its absence
could not turn anything red. A re-recording that is equally unconsumed will be
lost the same way, for the same reason. So this entry is not done until the
transcript exists **and** a spec replays it.

Three traps, in the order they bite:

- **No policy can produce the request.** `Compensating` refuses the block and
  `Lenient` drops it; either way it never reaches the wire, so `Client#send`
  is not a route to a recording. The body has to come from
  `Anthropic::Mapper.new(profile)` under a `Profile` built with
  `reasoning_signature_required: false`, posted through `Server#post`.
- **That `Profile` has to be constructed, not narrowed.** All three `with_*`
  helpers refuse this direction on purpose —
  `with_tool_call_signature_required` raises on the identical waiver, on the
  grounds that a catalog may add a requirement and never remove one. A spec
  doing this is exercising a configuration the library forbids, and must say
  so at the point it does it, or it reads as a supported deployment shape.
  *Record, never hand-write* still holds: the body is real mapper output, and
  only the profile behind it is the test's.
- **It costs a key, not money.** The request is rejected at schema validation,
  before any tokens are billed. Cheapness is not a reason to skip the
  `RECORD=1` two-step in `DEVELOPMENT.md`; the run *after* the recording is
  still the one that proves anything.

One thing to settle while writing it, because the answer decides where the
spec lives: a replay of this transcript asserts the *server's* schema, so it
cannot go red for any change to this shard. It is evidence, not a guard —
which is what `spec/live/` already is, and is the argument for putting it back
there rather than beside the offline guard it justifies.

---

## WILL FIX

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
  reject. Nothing in `Options` currently reasons about another of its own
  fields, and the first rule that does is worth deciding rather than
  assuming — including where it lives, since a conflict between two request
  options is neither a `Profile` fact nor a block question.

Neither hazard touches `Auto` or `None`, which is why they shipped without
waiting for this.

Also still out, and more cheaply: the fourth form, naming a specific tool the
model must call. It carries an argument, so adopting it turns `ToolChoice` from
an enum into a closed union and changes every caller's `case`. Additive in
meaning, breaking in shape. No caller in view.

### Emptying `tools` is a 400 on Anthropic, and nothing catches it

Found while building `tool_choice`, and separate from it. This endpoint rejects
any request whose history holds `tool_use` or `tool_result` blocks and does not
define tools:

```
Requests which include `tool_use` or `tool_result` blocks must define tools.
```

All four wire requests omit the `tools` key when the array is empty, so
`Options.new(tools: [] of Tool)` against a session with tool history builds a
request this shard knows will fail and sends it anyway.

`tool_choice` makes this *avoidable* — a caller no longer has any reason to
empty the array — but it does not make it impossible, and the failure is a
rejected request rather than a recorded loss.

The trap in fixing it: the constraint is documented by its error message rather
than by a schema, and nothing here has observed it. A guard built on that alone
would be the guessing this repo avoids, so this wants a recording first — which
is awkward in the usual way, since the request it needs is one no caller should
now be making. Worth checking whether the other three protocols have an
equivalent rule before writing anything protocol-specific; the OpenAI pair
rejects an *empty array* but the key's absence is a different question.

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
