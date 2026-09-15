require "../spec_helper"

# Tool declarations, output caps and tool choice, across four spellings of
# three ideas.
#
# These are *request* concerns, not session ones. A session that carried its
# own tool list would have acquired a home — the failure this shard exists to
# avoid — so `Options` rides on the call beside `policy` and `retention`, and
# nothing here touches `Session`.
#
# The gap these close was found live, not offline: an uncapped local model spent
# 4,096 tokens reasoning without reaching an answer, and no protocol but
# Anthropic could have stopped it.
private WEATHER_SCHEMA = <<-JSON
  {"type":"object","properties":{"location":{"type":"string","description":"City name"}},"required":["location"]}
  JSON

private def weather : Liaison::Tool
  Liaison::Tool.new("get_weather", "Look up the weather in a city", WEATHER_SCHEMA)
end

private def asked : M::Session
  session = M::Session.new("You are terse.")
  session << M::Message.user("Weather in Paris?")
  session
end

private def body(protocol : Liaison::ProtocolKind, options : Liaison::Options) : JSON::Any
  adapter = case protocol
            in Liaison::ProtocolKind::ChatCompletions then Liaison::ChatCompletionsAdapter.new
            in Liaison::ProtocolKind::Responses       then Liaison::ResponsesAdapter.new
            in Liaison::ProtocolKind::Anthropic       then Liaison::AnthropicAdapter.new
            in Liaison::ProtocolKind::Gemini          then Liaison::GeminiAdapter.new
            end

  exchange = adapter.prepare(asked, "test-model", C::Policy::Compensating,
    C::ReasoningRetention::All, 4096, options)
  JSON.parse(exchange.body)
end

describe "request options" do
  describe "tool declarations" do
    # Chat Completions is the only protocol that nests the declaration inside a
    # `function` object — the same hoisting instinct that puts tool *calls* on
    # the message rather than in the content.
    it "nests the declaration under a function object on Chat Completions" do
      tools = body(Liaison::ProtocolKind::ChatCompletions,
        Liaison::Options.new(tools: [weather]))["tools"].as_a

      tools.size.should eq 1
      tools[0]["type"].as_s.should eq "function"
      tools[0]["function"]["name"].as_s.should eq "get_weather"
      tools[0]["function"]["parameters"]["properties"]["location"].should_not be_nil
    end

    it "keeps the declaration flat on the Responses API" do
      tools = body(Liaison::ProtocolKind::Responses,
        Liaison::Options.new(tools: [weather]))["tools"].as_a

      tools[0]["name"].as_s.should eq "get_weather"
      tools[0]["parameters"]["required"].as_a.map(&.as_s).should eq ["location"]
    end

    # Anthropic names the field after what it constrains rather than what it
    # is: `input_schema`, not `parameters`.
    it "calls the schema input_schema on Anthropic" do
      tools = body(Liaison::ProtocolKind::Anthropic,
        Liaison::Options.new(tools: [weather]))["tools"].as_a

      tools[0]["name"].as_s.should eq "get_weather"
      tools[0]["input_schema"]["type"].as_s.should eq "object"
      tools[0]["parameters"]?.should be_nil
    end

    # Gemini nests twice: declarations inside `functionDeclarations`, inside an
    # entry of `tools`.
    it "double-nests declarations on Gemini" do
      tools = body(Liaison::ProtocolKind::Gemini,
        Liaison::Options.new(tools: [weather]))["tools"].as_a

      tools.size.should eq 1
      declarations = tools[0]["functionDeclarations"].as_a
      declarations.size.should eq 1
      declarations[0]["name"].as_s.should eq "get_weather"
    end

    it "carries the description where one is given" do
      [Liaison::ProtocolKind::Responses, Liaison::ProtocolKind::Anthropic].each do |protocol|
        tools = body(protocol, Liaison::Options.new(tools: [weather]))["tools"].as_a
        tools[0]["description"].as_s.should contain "weather"
      end
    end

    # The schema is emitted exactly as given. Rewriting a caller's schema would
    # be a worse failure than the provider's own error message — particularly
    # on Gemini, which accepts only a restricted OpenAPI subset, so a schema
    # valid elsewhere may be rejected there.
    it "passes the schema through untouched" do
      tools = body(Liaison::ProtocolKind::Responses,
        Liaison::Options.new(tools: [weather]))["tools"].as_a

      tools[0]["parameters"]["properties"]["location"]["description"].as_s
        .should eq "City name"
    end

    it "omits the tools field entirely when none are offered" do
      [Liaison::ProtocolKind::ChatCompletions, Liaison::ProtocolKind::Responses,
       Liaison::ProtocolKind::Anthropic, Liaison::ProtocolKind::Gemini].each do |protocol|
        body(protocol, Liaison::Options.new)["tools"]?.should be_nil
      end
    end

    it "refuses a tool with no name" do
      expect_raises(ArgumentError) { Liaison::Tool.new("") }
    end

    it "defaults to an empty object schema" do
      tool = Liaison::Tool.new("ping")
      JSON.parse(tool.parameters)["type"].as_s.should eq "object"
    end
  end

  describe "output caps" do
    it "spells the cap four ways" do
      options = Liaison::Options.new(max_output_tokens: 256)

      body(Liaison::ProtocolKind::ChatCompletions, options)["max_tokens"].as_i.should eq 256
      body(Liaison::ProtocolKind::Responses, options)["max_output_tokens"].as_i.should eq 256
      body(Liaison::ProtocolKind::Anthropic, options)["max_tokens"].as_i.should eq 256
      # The only protocol to put generation parameters in their own object.
      body(Liaison::ProtocolKind::Gemini, options)["generationConfig"]["maxOutputTokens"]
        .as_i.should eq 256
    end

    # Anthropic requires a value, so it always sends one. The other three omit
    # the field and take the provider's default.
    it "omits the cap where none is asked for, except on Anthropic" do
      options = Liaison::Options.new

      body(Liaison::ProtocolKind::ChatCompletions, options)["max_tokens"]?.should be_nil
      body(Liaison::ProtocolKind::Responses, options)["max_output_tokens"]?.should be_nil
      body(Liaison::ProtocolKind::Gemini, options)["generationConfig"]?.should be_nil
      body(Liaison::ProtocolKind::Anthropic, options)["max_tokens"].as_i.should eq 4096
    end

    # The positional `max_tokens` predates options on this protocol, so it
    # remains the fallback rather than becoming a second way to say the same
    # thing.
    it "lets options override Anthropic's positional default" do
      exchange = Liaison::AnthropicAdapter.new.prepare(asked, "test-model",
        C::Policy::Compensating, C::ReasoningRetention::All, 4096,
        Liaison::Options.new(max_output_tokens: 128))

      JSON.parse(exchange.body)["max_tokens"].as_i.should eq 128
    end
  end

  describe "tool choice" do
    # Three protocols take a bare string; Anthropic wraps it in an object and
    # Gemini nests it two deep under a shouted mode. One idea, three shapes.
    it "spells the choice four ways" do
      options = Liaison::Options.new(tools: [weather],
        tool_choice: Liaison::ToolChoice::None)

      body(Liaison::ProtocolKind::ChatCompletions, options)["tool_choice"].as_s.should eq "none"
      body(Liaison::ProtocolKind::Responses, options)["tool_choice"].as_s.should eq "none"
      body(Liaison::ProtocolKind::Anthropic, options)["tool_choice"]["type"].as_s.should eq "none"
      body(Liaison::ProtocolKind::Gemini, options)["toolConfig"]["functionCallingConfig"]["mode"]
        .as_s.should eq "NONE"
    end

    it "spells auto the same four ways" do
      options = Liaison::Options.new(tools: [weather],
        tool_choice: Liaison::ToolChoice::Auto)

      body(Liaison::ProtocolKind::ChatCompletions, options)["tool_choice"].as_s.should eq "auto"
      body(Liaison::ProtocolKind::Responses, options)["tool_choice"].as_s.should eq "auto"
      body(Liaison::ProtocolKind::Anthropic, options)["tool_choice"]["type"].as_s.should eq "auto"
      body(Liaison::ProtocolKind::Gemini, options)["toolConfig"]["functionCallingConfig"]["mode"]
        .as_s.should eq "AUTO"
    end

    # The guarantee this option exists to keep: the tools are still declared.
    # Emptying the array instead is what a caller had to do before, and it is a
    # 400 on Anthropic for any session carrying tool history.
    it "keeps the declarations on the wire" do
      options = Liaison::Options.new(tools: [weather],
        tool_choice: Liaison::ToolChoice::None)

      [Liaison::ProtocolKind::ChatCompletions, Liaison::ProtocolKind::Responses,
       Liaison::ProtocolKind::Anthropic, Liaison::ProtocolKind::Gemini].each do |protocol|
        body(protocol, options)["tools"]?.should_not be_nil
      end
    end

    # Absent means absent. Asserted against a request that *does* offer tools,
    # since the interesting case is a caller who declares them and says nothing
    # about how they may be used — this is what keeps every recorded transcript
    # valid.
    it "emits nothing when no choice is asked for" do
      options = Liaison::Options.new(tools: [weather])

      body(Liaison::ProtocolKind::ChatCompletions, options)["tool_choice"]?.should be_nil
      body(Liaison::ProtocolKind::Responses, options)["tool_choice"]?.should be_nil
      body(Liaison::ProtocolKind::Anthropic, options)["tool_choice"]?.should be_nil
      body(Liaison::ProtocolKind::Gemini, options)["toolConfig"]?.should be_nil
    end

    # A 400 on the OpenAI protocols — `tool_choice is only allowed when tools
    # are specified` — so it is refused here rather than sent and rejected.
    it "refuses a choice with no tools to choose from" do
      expect_raises(ArgumentError, /tools/) do
        Liaison::Options.new(tool_choice: Liaison::ToolChoice::None)
      end
    end
  end

  # Options are a request concern; the session is unchanged by them, and two
  # requests differing only in options must produce the same conversation.
  describe "separation from history" do
    it "does not alter the conversation" do
      plain = body(Liaison::ProtocolKind::ChatCompletions, Liaison::Options.new)
      armed = body(Liaison::ProtocolKind::ChatCompletions,
        Liaison::Options.new(tools: [weather], max_output_tokens: 64))

      armed["messages"].to_json.should eq plain["messages"].to_json
    end
  end
end
