require "../../spec_helper"
require "../../support/cli_output"
require "file_utils"
require "../../../src/liaison_cli/config"
require "../../../src/liaison_cli/sessions"
require "../../../src/liaison_cli/commands/start"

# In-process, same reasoning as every other spec in this shard: a compiler
# error surfaces directly here rather than inside a subprocess. `Start.run`
# goes through the real `Server#post`, so Wiretap intercepts it exactly like
# `spec/live/ollama_spec.cr` does — record once against a local Ollama with
# `RECORD=1`, replays offline for everyone after. Free: local, no API key.
private MODEL = "gemma4:26b-mxfp8"

private def with_sandbox(&) : Nil
  tmp = File.join(Dir.tempdir, "liaison-cli-start-spec-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(File.join(tmp, ".liaison"))
  config_path = File.join(tmp, "liaison.yaml")
  File.write(config_path, <<-YAML)
    servers:
      ollama:
        protocol: chat_completions
        url: http://localhost:11434
    deployments:
      ollama:
        server: ollama
        model: #{MODEL}
    YAML

  # $LIAISON_CONFIG / $LIAISON_HOME, not Dir.cd and not relying on an
  # unshadowed $CWD or $HOME. Two separate reasons: Dir.cd would move
  # Wiretap's own relative transcript path into this sandbox too — the
  # earlier bug — and a real liaison.yaml or .liaison left by an actual `liaison`
  # invocation on this machine would otherwise win over the sandboxed one,
  # since $CWD is checked before either explicit override.
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

describe Liaison::Cli::Commands::Start do
  it "creates a session, saves it, and records which deployment answered" do
    with_sandbox do
      Wiretap.intercept("liaison_cli_start_ollama") do
        Liaison::Cli::Commands::Start.run(["ollama", "What is the tallest mountain on Earth?",
                                          "Answer in one short sentence."])
      end

      ids = Dir.children(Liaison::Cli::Sessions.folder)
      ids.size.should eq(1)
      id = ids.first

      Liaison::Cli::Sessions.latest_deployment(id).should eq("ollama")

      session = Liaison::Cli::Sessions.latest(id)
      session.messages.size.should eq(2)
      session.messages.first.role.should eq(M::Role::User)
      session.messages.last.role.should eq(M::Role::Assistant)
      session.messages.last.content.select(M::TextBlock).should_not be_empty
    end
  end

  # Both of these raise before the request is made, so they need no cassette.
  # That is also the behaviour under test: a refusal is only useful if it
  # arrives before the money is spent.
  it "refuses an --id that is already a session, and points at continue" do
    with_sandbox do
      Dir.mkdir_p(Liaison::Cli::Sessions.path_for("tax-questions"))
      expect_raises(Liaison::Cli::SessionError, /already exists.*liaison continue tax-questions/) do
        Liaison::Cli::Commands::Start.run(["ollama", "hello", "--id", "tax-questions"])
      end
    end
  end

  it "refuses an --id that would leave the sessions folder" do
    with_sandbox do
      expect_raises(Liaison::Cli::SessionError, /not a usable session id/) do
        Liaison::Cli::Commands::Start.run(["ollama", "hello", "--id", "../escape"])
      end
    end
  end

  it "raises naming the deployment, before ever calling out, for an unknown one" do
    with_sandbox do
      expect_raises(Liaison::Cli::ConfigError, /"nonexistent"/) do
        Liaison::Cli::Commands::Start.run(["nonexistent", "hello"])
      end
    end
  end

  it "raises a usage error when no prompt is given" do
    with_sandbox do
      expect_raises(ArgumentError, /usage/) do
        Liaison::Cli::Commands::Start.run(["ollama"])
      end
    end
  end
end
