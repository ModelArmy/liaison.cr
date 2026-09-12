require "file_utils"

# A session written to a file and read back from it.
#
# `MPSH::Archive` is the real thing here, not a stand-in — the helper only owns
# the tempfile and the cleanup, which is all `Elelem::Cli::Sessions` owns too
# once its id minting, folder layout and snapshot pruning are set aside. So a
# spec using this is testing the archive rather than a second implementation of
# it written by the same hand.
module SavedSession
  # Yields a path that does not exist yet and removes it afterwards.
  def self.in_a_file(&)
    path = File.join(Dir.tempdir, "elelem-e2e-#{Random.rand(1_000_000)}.json")
    begin
      yield path
    ensure
      FileUtils.rm_rf(path)
    end
  end

  def self.save(session : M::Session, path : String) : Nil
    File.write(path, M::Archive.write(session))
  end

  def self.load(path : String) : M::Session
    M::Archive.read(File.read(path))
  end

  # Saves, reloads, and returns the reloaded session. The round trip most specs
  # want, in one call.
  def self.round_trip(session : M::Session, path : String) : M::Session
    save(session, path)
    load(path)
  end
end
