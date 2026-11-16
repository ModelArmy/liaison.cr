require "../spec_helper"

# Frames of the wrong shape, in all four assemblers at once. A frame that is
# JSON but not an object, or whose fields have the wrong shapes, carries
# nothing an assembler can read, so it is skipped like a keep-alive rather
# than raising the stdlib's untyped error from indexing a non-object.

private def assemblers : Array(Liaison::Streaming::Assembler)
  [
    P::ChatCompletions::Assembler.new(P::ChatCompletions::Exporter.new),
    P::Responses::Assembler.new(P::Responses::Exporter.new),
    P::Anthropic::Assembler.new(P::Anthropic::Exporter.new),
    P::Gemini::Assembler.new(P::Gemini::Exporter.new),
  ] of Liaison::Streaming::Assembler
end

private def events(assembler : Liaison::Streaming::Assembler, data : String,
                   name : String? = nil) : Array(Liaison::Streaming::Event)
  collected = [] of Liaison::Streaming::Event
  assembler.absorb(S::Sse::Frame.new(data, name)) { |event| collected << event }
  collected
end

describe "frames of the wrong shape" do
  it "skips a frame that is JSON but not an object" do
    assemblers.each do |assembler|
      ["[1, 2]", %("text"), "7", "null"].each do |data|
        events(assembler, data).should be_empty
      end
      assembler.complete?.should be_false
    end
  end

  it "skips fields of the wrong shape inside a frame" do
    events(P::ChatCompletions::Assembler.new(P::ChatCompletions::Exporter.new),
      %({"choices": ["x", {"delta": "y"}]})).should be_empty
    events(P::Anthropic::Assembler.new(P::Anthropic::Exporter.new),
      %({"type": "content_block_start", "index": 0, "content_block": "x"}),
      "content_block_start").should be_empty
    events(P::Responses::Assembler.new(P::Responses::Exporter.new),
      %({"type": "response.output_item.added", "item": "x"}),
      "response.output_item.added").should be_empty
    events(P::Gemini::Assembler.new(P::Gemini::Exporter.new),
      %({"candidates": ["x", {"content": "y"}]})).should be_empty
  end
end
