require "json"

module Liaison::Protocol::ChatCompletions
  # The request half of the wire form, shaped like OpenAI's JSON rather than
  # MPSH: string roles including `system` and `tool`, tool calls as a message
  # field, content as a string or part array, and images fused into `data:`
  # URIs.
  module Wire
    # Which spelling of the output cap this deployment wants. OpenAI's
    # reasoning models reject `max_tokens` and require `max_completion_tokens`
    # (confirmed live on Azure), while Ollama, LM Studio and llama.cpp accept
    # only `max_tokens`.
    #
    # A deployment fact, not a `Profile` one, and `MaxTokens` is the default
    # everywhere: the new spelling sent to an emulator would not degrade, it
    # would leave output uncapped. A deployment that needs the new spelling
    # says so; see `ChatCompletionsAdapter#initialize`.
    enum MaxTokensField
      MaxTokens
      MaxCompletionTokens
    end

    # A single piece of message content.
    abstract struct Part
      abstract def to_json(json : JSON::Builder)
    end

    struct TextPart < Part
      getter text : String

      def initialize(@text : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "text"
          json.field "text", @text
        end
      end
    end

    # The fused form, built at map time and never stored.
    struct ImagePart < Part
      getter url : String

      def initialize(media_type : String, base64 : String)
        @url = "data:#{media_type};base64,#{base64}"
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "image_url"
          json.field "image_url" do
            json.object { json.field "url", @url }
          end
        end
      end
    end

    struct AudioPart < Part
      getter base64 : String
      getter format : String

      def initialize(@base64 : String, @format : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "input_audio"
          json.field "input_audio" do
            json.object do
              json.field "data", @base64
              json.field "format", @format
            end
          end
        end
      end
    end

    struct FilePart < Part
      getter base64 : String
      getter name : String

      def initialize(@base64 : String, @name : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "file"
          json.field "file" do
            json.object do
              json.field "filename", @name
              json.field "file_data", @base64
            end
          end
        end
      end
    end

    # A tool call, hoisted out of content onto the message.
    struct ToolCall
      getter id : String
      getter name : String
      getter arguments : String

      def initialize(@id : String, @name : String, @arguments : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "id", @id
          json.field "type", "function"
          json.field "function" do
            json.object do
              json.field "name", @name
              json.field "arguments", @arguments
            end
          end
        end
      end
    end

    # Roles are provider spellings: `system` and `tool` map onto MPSH's two
    # roles in both directions.
    struct Message
      getter role : String
      getter content : String | Array(Part)?
      getter tool_calls : Array(ToolCall)?
      getter tool_call_id : String?
      getter refusal : String?
      getter reasoning_content : String?
      # True for a message invented to make the request legal. Never
      # serialized; export discards it.
      getter? synthetic : Bool

      def initialize(@role : String,
                     @content : String | Array(Part)? = nil,
                     @tool_calls : Array(ToolCall)? = nil,
                     @tool_call_id : String? = nil,
                     @refusal : String? = nil,
                     @reasoning_content : String? = nil,
                     @synthetic : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "role", @role
          case body = @content
          in String      then json.field "content", body
          in Array(Part) then json.field("content") { json.array { body.each(&.to_json(json)) } }
          in Nil         then json.field "content", nil
          end
          if calls = @tool_calls
            json.field("tool_calls") { json.array { calls.each(&.to_json(json)) } }
          end
          if id = @tool_call_id
            json.field "tool_call_id", id
          end
          if text = @refusal
            json.field "refusal", text
          end
          if text = @reasoning_content
            json.field "reasoning_content", text
          end
        end
      end
    end

    # A tool offered to the model, wrapped in a `function` object under a
    # `type` discriminator.
    struct ToolDeclaration
      getter name : String
      getter description : String?
      getter parameters : String

      def initialize(@name : String, @description : String?, @parameters : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "function"
          json.field("function") do
            json.object do
              json.field "name", @name
              @description.try { |text| json.field "description", text }
              # Emitted raw: the schema is already JSON.
              json.field("parameters") { json.raw @parameters }
            end
          end
        end
      end
    end

    struct Request
      getter model : String
      getter messages : Array(Message)
      getter tools : Array(ToolDeclaration)
      getter max_tokens : Int32?
      getter max_tokens_field : MaxTokensField
      # A bare string at the top level. `nil` omits the field, leaving the
      # model's default.
      getter reasoning_effort : String?
      # A bare string, as on Responses; Anthropic wraps it in an object.
      getter tool_choice : String?
      # Asks for a frame stream. Set by the adapter through `with_stream`, not
      # by the mapper: streaming is about the call, not the session.
      getter? stream : Bool

      def initialize(@model : String, @messages : Array(Message),
                     @tools : Array(ToolDeclaration) = [] of ToolDeclaration,
                     @max_tokens : Int32? = nil,
                     @reasoning_effort : String? = nil,
                     @max_tokens_field : MaxTokensField = MaxTokensField::MaxTokens,
                     @tool_choice : String? = nil,
                     @stream : Bool = false)
      end

      # The same request, streamed. A copy rather than a setter, since a setter
      # on a struct edits whichever copy the caller holds.
      def with_stream(value : Bool) : Request
        Request.new(@model, @messages, @tools, @max_tokens,
          @reasoning_effort, @max_tokens_field, @tool_choice, value)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "model", @model
          json.field("messages") { json.array { @messages.each(&.to_json(json)) } }
          unless @tools.empty?
            json.field("tools") { json.array { @tools.each(&.to_json(json)) } }
          end
          @max_tokens.try do |value|
            field = @max_tokens_field.max_tokens? ? "max_tokens" : "max_completion_tokens"
            json.field field, value
          end
          @tool_choice.try { |value| json.field "tool_choice", value }
          @reasoning_effort.try { |value| json.field "reasoning_effort", value }
          if @stream
            json.field "stream", true
            # Without this a streamed reply reports no usage. Servers that
            # honour it end with a chunk whose `choices` is empty and which
            # carries only `usage`; others ignore it.
            json.field("stream_options") { json.object { json.field "include_usage", true } }
          end
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
