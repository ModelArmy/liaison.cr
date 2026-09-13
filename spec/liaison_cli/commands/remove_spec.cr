require "../../spec_helper"
require "../../support/cli_output"
require "file_utils"
require "../../../src/liaison_cli/sessions"
require "../../../src/liaison_cli/commands/delete"
require "../../../src/liaison_cli/commands/prune"

# `delete` and `prune` touch no network, like `list` and `show`: they act on
# what `start`/`continue` already wrote. No Wiretap, nothing recorded.
#
# Sandboxed with `$LIAISON_HOME` rather than `Dir.cd`, for the reason
# `start_spec.cr` records at length.
private def with_sandbox(&) : Nil
  tmp = File.join(Dir.tempdir, "liaison-cli-remove-spec-#{Random.rand(1_000_000)}")
  Dir.mkdir_p(File.join(tmp, ".liaison"))

  original_home = ENV["LIAISON_HOME"]?
  ENV["LIAISON_HOME"] = File.join(tmp, ".liaison")
  begin
    yield
  ensure
    original_home ? (ENV["LIAISON_HOME"] = original_home) : ENV.delete("LIAISON_HOME")
    FileUtils.rm_rf(tmp)
  end
end

private def seed(id : String, deployment : String) : Nil
  session = M::Session.new
  session << M::Message.user("a question")
  session << M::Message.assistant("a reply")
  Liaison::Cli::Sessions.snapshot(id, session, deployment)
end

describe Liaison::Cli::Commands::Delete do
  it "removes the session and says what it cost" do
    with_sandbox do
      seed("brisk-comet", "ollama")
      seed("brisk-comet", "ollama")

      _, warned = captured { Liaison::Cli::Commands::Delete.run(["brisk-comet"]) }

      Liaison::Cli::Sessions.exists?("brisk-comet").should be_false
      warned.should contain("brisk-comet")
      warned.should contain("2 snapshots")
    end
  end

  it "leaves every other session alone" do
    with_sandbox do
      seed("brisk-comet", "ollama")
      seed("keen-otter", "ollama")

      captured { Liaison::Cli::Commands::Delete.run(["brisk-comet"]) }

      Liaison::Cli::Sessions.list.should eq(["keen-otter"])
    end
  end

  # The likeliest reason to reach for this verb. `list` renders a session it
  # cannot parse as `<unreadable>`, and a delete that insisted on reading what
  # it was about to remove would fail exactly when it was most wanted.
  it "removes a session whose snapshots will not parse" do
    with_sandbox do
      seed("brisk-comet", "ollama")
      File.write(File.join(Liaison::Cli::Sessions.path_for("brisk-comet"), "9999999999999-ollama.json"), "{ not json")

      captured { Liaison::Cli::Commands::Delete.run(["brisk-comet"]) }

      Liaison::Cli::Sessions.exists?("brisk-comet").should be_false
    end
  end

  it "reports a session that was never there" do
    with_sandbox do
      expect_raises(Liaison::Cli::SessionError, /no session named/) do
        Liaison::Cli::Commands::Delete.run(["no-such-thing"])
      end
    end
  end

  # `path_for` validates before anything becomes a path, so the traversal
  # question was settled before this verb existed. Pinned here anyway: `delete`
  # is the verb where a gap in that guard would be worst, and a spec is how a
  # future refactor learns that it mattered.
  it "refuses an id that tries to leave the sessions folder" do
    with_sandbox do
      expect_raises(Liaison::Cli::SessionError) do
        Liaison::Cli::Commands::Delete.run(["../../etc"])
      end
    end
  end

  it "wants exactly one session id" do
    with_sandbox do
      expect_raises(ArgumentError, /usage/) { Liaison::Cli::Commands::Delete.run([] of String) }
      expect_raises(ArgumentError, /usage/) { Liaison::Cli::Commands::Delete.run(["one", "two"]) }
    end
  end
end

describe Liaison::Cli::Commands::Prune do
  it "keeps the newest snapshots and removes the rest" do
    with_sandbox do
      seed("brisk-comet", "first")
      seed("brisk-comet", "second")
      seed("brisk-comet", "third")

      _, warned = captured { Liaison::Cli::Commands::Prune.run(["brisk-comet", "--keep", "2"]) }

      remaining = Liaison::Cli::Sessions.snapshots("brisk-comet")
      remaining.size.should eq(2)
      remaining.none?(&.includes?("first")).should be_true
      warned.should contain("Pruned 1")
      warned.should contain("2 kept")
    end
  end

  # The session survives pruning as a working session, which is the whole
  # difference between this verb and `delete`.
  it "leaves the session continuable" do
    with_sandbox do
      seed("brisk-comet", "ollama")
      seed("brisk-comet", "ollama-responses")

      captured { Liaison::Cli::Commands::Prune.run(["brisk-comet", "--keep", "1"]) }

      Liaison::Cli::Sessions.latest_deployment("brisk-comet").should eq("ollama-responses")
      Liaison::Cli::Sessions.latest("brisk-comet").messages.size.should eq(2)
    end
  end

  it "says so plainly when there is nothing to remove" do
    with_sandbox do
      seed("brisk-comet", "ollama")

      _, warned = captured { Liaison::Cli::Commands::Prune.run(["brisk-comet", "--keep", "5"]) }

      Liaison::Cli::Sessions.snapshots("brisk-comet").size.should eq(1)
      warned.should contain("Nothing to prune")
    end
  end

  # No default, deliberately: every value is a judgement about how much
  # history is worth keeping, and guessing one on the person's behalf is how an
  # irreversible verb becomes a surprising one.
  it "refuses to guess how much to keep" do
    with_sandbox do
      seed("brisk-comet", "ollama")

      expect_raises(ArgumentError, /usage/) { Liaison::Cli::Commands::Prune.run(["brisk-comet"]) }
      Liaison::Cli::Sessions.snapshots("brisk-comet").size.should eq(1)
    end
  end

  # A session with no snapshots is indistinguishable from a corrupt one, and
  # `delete` is the verb for meaning that.
  it "refuses to leave a session with nothing in it" do
    with_sandbox do
      seed("brisk-comet", "ollama")

      expect_raises(Liaison::Cli::SessionError, /fewer than one/) do
        Liaison::Cli::Commands::Prune.run(["brisk-comet", "--keep", "0"])
      end
      Liaison::Cli::Sessions.snapshots("brisk-comet").size.should eq(1)
    end
  end

  it "wants a number" do
    with_sandbox do
      seed("brisk-comet", "ollama")

      expect_raises(ArgumentError, /whole number/) do
        Liaison::Cli::Commands::Prune.run(["brisk-comet", "--keep", "some"])
      end
    end
  end

  it "reports a session that was never there" do
    with_sandbox do
      expect_raises(Liaison::Cli::SessionError, /no session named/) do
        Liaison::Cli::Commands::Prune.run(["no-such-thing", "--keep", "1"])
      end
    end
  end
end
