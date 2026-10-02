require "./liaison/version"

# Canonical layer. Nothing under `mpsh/` knows that HTTP, or any provider,
# exists — and nothing under it serializes into a request body.
require "./liaison/mpsh/meta"
require "./liaison/mpsh/payload"
require "./liaison/mpsh/block"
require "./liaison/mpsh/message"
require "./liaison/mpsh/annotation"
require "./liaison/mpsh/session"
require "./liaison/mpsh/archive"
require "./liaison/mpsh/repair"
require "./liaison/mpsh/turns"
require "./liaison/mpsh/translation"

# Capability layer. Depends on the canonical layer; never the reverse.
require "./liaison/reasoning"
require "./liaison/capability/profile"
require "./liaison/capability/policy"
require "./liaison/capability/resolver"
require "./liaison/capability/structural"
require "./liaison/capability/retention"
require "./liaison/capability/reasoning_control"
require "./liaison/capability/catalog"

# Streaming vocabulary. Depends on the canonical types only; the protocol
# assemblers and the live layer depend on it. `Sse` is the framing all four
# protocols share.
require "./liaison/streaming/sse"
require "./liaison/streaming/event"
require "./liaison/streaming/turn"
require "./liaison/streaming/assembler"

# Protocol layer. One directory per protocol: capabilities, wire vocabulary
# (request out, response in), mapper and exporter.
require "./liaison/options"
require "./liaison/protocol/errors"
# - Chat completions
require "./liaison/protocol/chat_completions/capabilities"
require "./liaison/protocol/chat_completions/wire/request"
require "./liaison/protocol/chat_completions/wire/response"
require "./liaison/protocol/chat_completions/mapper"
require "./liaison/protocol/chat_completions/export"
require "./liaison/protocol/chat_completions/stream"
# - Responses
require "./liaison/protocol/responses/capabilities"
require "./liaison/protocol/responses/wire/request"
require "./liaison/protocol/responses/wire/response"
require "./liaison/protocol/responses/mapper"
require "./liaison/protocol/responses/export"
require "./liaison/protocol/responses/stream"
# - Anthropic
require "./liaison/protocol/anthropic/capabilities"
require "./liaison/protocol/anthropic/wire/request"
require "./liaison/protocol/anthropic/wire/response"
require "./liaison/protocol/anthropic/mapper"
require "./liaison/protocol/anthropic/export"
require "./liaison/protocol/anthropic/stream"
# - Gemini
require "./liaison/protocol/gemini/capabilities"
require "./liaison/protocol/gemini/wire/request"
require "./liaison/protocol/gemini/wire/response"
require "./liaison/protocol/gemini/mapper"
require "./liaison/protocol/gemini/export"
require "./liaison/protocol/gemini/stream"

# The live layer: a deployment, the protocol it speaks, and one request per
# send. `adapters/<protocol>.cr` declares an adapter;
# `adapters/<deployment>/<protocol>.cr` amends one for a deployment.
require "./liaison/server"
require "./liaison/adapters/adapter"
require "./liaison/adapters/chat_completions"
require "./liaison/adapters/responses"
require "./liaison/adapters/anthropic"
require "./liaison/adapters/gemini"
require "./liaison/adapters/azure/chat_completions"
require "./liaison/adapters/azure/responses"
require "./liaison/provider"
require "./liaison/client"

# Caller-facing tool execution. Depends on `mpsh/` and on `Tool` in
# `options.cr`, not on the live layer, so a `Toolbox` can be tested without a
# `Client`.
require "./liaison/function"
require "./liaison/toolbox"

module Liaison
end
