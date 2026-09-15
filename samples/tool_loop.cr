#! /usr/bin/env crystal
#
# A tool the model can actually run, and the turn loop that runs it.
#
#     crystal run samples/tool_loop.cr
#
# Needs a local Ollama with one model pulled. Set $OLLAMA_MODEL to use something
# other than the default below.
#
# `Client#send` performs one exchange and returns. The loop is the caller's,
# deliberately — this file is what that caller looks like. `Toolbox#dispatch`
# returning `nil` is the exit condition: no calls to run means the model
# answered rather than asked.
#
# `spec/end_to_end/tool_turn_spec.cr` tests this against a live endpoint,
# including the part this file does not show: a completed tool exchange handed
# to a second protocol.

require "../src/liaison"

alias M = Liaison::MPSH

MODEL = ENV["OLLAMA_MODEL"]? || "gemma4:26b-mxfp8"

# A `Function` is a declaration plus its handler. The declaration is what the
# model sees; `call` is what runs. Arguments arrive parsed, as an `M::Object`,
# so there is no JSON to unpick here.
class Weather
  include Liaison::Function

  def name : String
    "get_weather"
  end

  def description : String?
    "Look up the current weather in a city"
  end

  def parameters : String
    %({"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]})
  end

  def call(arguments : M::Object) : Array(M::Block)
    city = arguments["city"]?.as?(String) || "somewhere"
    puts "  → running get_weather(#{city})"
    [M::TextBlock.new(%({"city":"#{city}","temp_c":18,"conditions":"light rain"})).as(M::Block)]
  end
end

server = Liaison::Server.new("ollama", "http://localhost:11434")
client = Liaison::Client.new(
  Liaison::Provider.for(server, Liaison::ProtocolKind::ChatCompletions))

toolbox = Liaison::Toolbox.new([Weather.new] of Liaison::Function)
options = Liaison::Options.new(tools: toolbox.tools,
  reasoning: Liaison::Reasoning::Off.new)

session = M::Session.new("Use the supplied tools when they apply.")
session << M::Message.user("What is the weather in Paris? Use the get_weather tool.")

# The loop. Bounded, because a model that keeps calling is a real outcome and
# an unbounded loop is a real bill.
4.times do
  reply, _ = client.send(session, MODEL, options: options)
  session << reply

  # `#dispatch` repairs its argument before reading it, so a turn cut mid-call
  # runs nothing rather than running half a plan.
  results = toolbox.dispatch(reply)
  unless results
    puts reply.text
    break
  end

  session << results
end

# `sendable?` is the invariant the whole arrangement protects: every call in the
# session is paired with a result. A loop that dispatched from an unrepaired
# reply would break it from the other direction.
puts "\nsendable: #{M::Repair.sendable?(session)}"
