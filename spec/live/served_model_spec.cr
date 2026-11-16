require "../spec_helper"

# A recording is evidence about the model its request names. Google has served
# one model name with another (`gemini-3.5-flash` answered by
# `gemini-3.6-flash`), which relabels a re-recording's evidence silently. So
# every recorded Gemini reply's `modelVersion` must equal the model in its URL;
# a reply without one, such as an error, is not checked. Offline: reads the
# transcripts rather than replaying them.
describe "recorded Gemini replies" do
  it "were served by the model each request names" do
    mismatches = [] of String

    Dir.glob("spec/transcripts/*.json").sort.each do |path|
      JSON.parse(File.read(path))["interactions"].as_a.each_with_index do |interaction, index|
        url = interaction["request"]["url"].as_s
        next unless url.includes?("generativelanguage.googleapis.com")
        asked = url[/models\/([^:]+):/, 1]

        body = interaction["response"]["body"].as_s? || ""
        body.scan(/"modelVersion":\s*"([^"]+)"/).map(&.[1]).uniq.each do |served|
          next if served == asked
          mismatches << "#{File.basename(path)}[#{index}]: asked #{asked}, served by #{served}"
        end
      end
    end

    mismatches.should be_empty
  end
end
