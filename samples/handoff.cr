#! /usr/bin/env crystal
#
# The product claim in one file: answer a question on one protocol, write the
# session to disk, read it back, and continue the same conversation on another.
#
#     crystal run examples/handoff.cr
#
# Needs a local Ollama with one model pulled, since Ollama serves Chat
# Completions, Responses and Anthropic-compatible endpoints from one port. Set
# $OLLAMA_MODEL to use something other than the default below.
#
# `spec/end_to_end/handoff_spec.cr` tests all of this and more. This file is
# documentation: it shows the shape, and stays thin enough that it cannot
# disagree with the spec about what the shape is.

require "../src/liaison"

alias M = Liaison::MPSH

MODEL = ENV["OLLAMA_MODEL"]? || "gemma4:26b-mxfp8"
FILE  = File.join(Dir.tempdir, "liaison-handoff-example.json")

server = Liaison::Server.new("ollama", "http://localhost:11434")

def ask(server, protocol, session, options)
  client = Liaison::Client.new(Liaison::Provider.for(server, protocol))
  client.send(session, MODEL, options: options)
end

# Reasoning off, deliberately. Ollama reasons on every endpoint and cannot mint
# an Anthropic thought signature, so a reasoning block carried into an Anthropic
# request is degraded and refused. That is a real property worth meeting, but it
# belongs to retention rather than to portability, and it would obscure what
# this file is about.
options = Liaison::Options.new(reasoning: Liaison::Reasoning::Off.new)

session = M::Session.new("Answer in one short sentence.")
session << M::Message.user("What is the tallest mountain on Earth?")

reply, _ = ask(server, Liaison::ProtocolKind::ChatCompletions, session, options)
session << reply
puts "chat_completions: #{reply.text}"

# The hop. Everything after this reads from the file; the in-memory session is
# not reused, which is the only way to show that the file was sufficient.
File.write(FILE, M::Archive.write(session))
resumed = M::Archive.read(File.read(FILE))

resumed << M::Message.user("And the second tallest?")
reply, report = ask(server, Liaison::ProtocolKind::Anthropic, resumed, options)
resumed << reply
puts "anthropic:        #{reply.text}"

# The report is half of what `send` returns, and ignoring it is how a silent
# degradation stays silent. On a handoff this clean it will usually be empty.
if report.annotations.empty?
  puts "\nnothing was lost crossing protocols."
else
  puts "\nwhat the handoff cost:"
  report.annotations.each { |note| puts "  #{note}" }
end

puts "session saved at #{FILE} — nothing in it names a vendor as its owner."
