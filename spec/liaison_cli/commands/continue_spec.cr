require "../../spec_helper"
require "../../support/cli_output"
require "file_utils"
require "../../../src/liaison_cli/config"
require "../../../src/liaison_cli/sessions"
require "../../../src/liaison_cli/commands/start"
require "../../../src/liaison_cli/commands/continue"

# Two deployments, same server, same model, different protocol — the
# cross-protocol handoff `liaison` exists for, proven with one already-pulled
# Ollama model rather than needing a second one downloaded just for this
# spec. Same free-recording reasoning as `start_spec.cr`.
private MODEL = "gemma4:26b-mxfp8"

private def with_sandbox(&) : Nil
  tmp = File.join(Dir.tempdir, "liaison-cli-continue-spec-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(File.join(tmp, ".liaison"))
  config_path = File.join(tmp, "liaison.yaml")
  File.write(config_path, <<-YAML)
    servers:
      ollama:
        protocol: chat_completions
        url: http://localhost:11434
      ollama-responses:
        protocol: responses
        url: http://localhost:11434
    deployments:
      ollama:
        server: ollama
        model: #{MODEL}
      ollama-responses:
        server: ollama-responses
        model: #{MODEL}
    YAML

  # See start_spec.cr's with_sandbox for why this is $LIAISON_CONFIG /
  # $LIAISON_HOME rather than Dir.cd or a bare $HOME override.
  original_home = ENV["LIAISON_HOME"]?
  original_config = ENV["LIAISON_CONFIG"]?
  ENV["LIAISON_HOME"] = File.join(tmp, ".liaison")
  ENV["LIAISON_CONFIG"] = config_path
  begin
    # Every command here prints a reply, and a recorded run prints it just as
    # loudly as a live one — which buried real failures under transcripts.
    # Wrapped at the sandbox rather than per test because no spec in this file
    # asserts on output; one that wants to can call `captured` itself.
    captured { yield }
  ensure
    original_home ? (ENV["LIAISON_HOME"] = original_home) : ENV.delete("LIAISON_HOME")
    original_config ? (ENV["LIAISON_CONFIG"] = original_config) : ENV.delete("LIAISON_CONFIG")
    FileUtils.rm_rf(tmp)
  end
end

# Shared name deliberately: both specs below start from the same deployment
# with the same prompt, so the request is byte-identical — the same rule
# `ollama_spec.cr` already documents for sharing a transcript name.
private def started : String
  Wiretap.intercept("liaison_cli_continue_start") do
    Liaison::Cli::Commands::Start.run(["ollama", "What is the tallest mountain on Earth?",
                                      "Answer in one short sentence."])
  end
  Dir.children(Liaison::Cli::Sessions.folder).first
end

describe Liaison::Cli::Commands::Continue do
  it "reuses the last deployment when --on is not given" do
    with_sandbox do
      id = started

      Wiretap.intercept("liaison_cli_continue_same_deployment") do
        Liaison::Cli::Commands::Continue.run([id, "Why is that?"])
      end

      Liaison::Cli::Sessions.latest_deployment(id).should eq("ollama")
      Liaison::Cli::Sessions.latest(id).messages.size.should eq(4)
    end
  end

  it "switches deployment when --on is given, carrying the session to a different protocol" do
    with_sandbox do
      id = started

      Wiretap.intercept("liaison_cli_continue_switch") do
        Liaison::Cli::Commands::Continue.run([id, "Why is that?", "--on", "ollama-responses"])
      end

      Liaison::Cli::Sessions.latest_deployment(id).should eq("ollama-responses")
      Liaison::Cli::Sessions.latest(id).messages.size.should eq(4)
    end
  end

  it "raises naming the session id when asked to continue one that never started" do
    with_sandbox do
      expect_raises(Liaison::Cli::SessionError, /nonexistent-session/) do
        Liaison::Cli::Commands::Continue.run(["nonexistent-session", "hello"])
      end
    end
  end

  it "raises a usage error when no prompt is given" do
    with_sandbox do
      expect_raises(ArgumentError, /usage/) do
        Liaison::Cli::Commands::Continue.run(["any-id-at-all"])
      end
    end
  end
end
