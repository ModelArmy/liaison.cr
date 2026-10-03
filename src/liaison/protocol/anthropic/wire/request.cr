require "json"

module Liaison::Protocol::Anthropic
  # The request half of the Messages API wire form. Tool calls, tool results
  # and thinking are content blocks, as in MPSH, and `tool_result.content` is
  # a block array that may include images.
  module Wire
    abstract struct Block
      abstract def to_json(json : JSON::Builder)
    end

    struct TextBlock < Block
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

    # Media type and base64 kept separate, as MPSH stores them.
    struct ImageBlock < Block
      getter media_type : String
      getter base64 : String

      def initialize(@media_type : String, @base64 : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "image"
          json.field "source" do
            json.object do
              json.field "type", "base64"
              json.field "media_type", @media_type
              json.field "data", @base64
            end
          end
        end
      end
    end

    struct DocumentBlock < Block
      getter media_type : String
      getter base64 : String
      getter title : String?

      def initialize(@media_type : String, @base64 : String, @title : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "document"
          json.field "source" do
            json.object do
              json.field "type", "base64"
              json.field "media_type", @media_type
              json.field "data", @base64
            end
          end
          if value = @title
            json.field "title", value
          end
        end
      end
    end

    struct ToolUseBlock < Block
      getter id : String
      getter name : String
      getter input : String

      def initialize(@id : String, @name : String, @input : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "tool_use"
          json.field "id", @id
          json.field "name", @name
          # A structured object here, not a JSON string as on the OpenAI
          # protocols.
          json.field "input" { json.raw @input }
        end
      end
    end

    # `content` is a nested block array, so `[text, image]` needs no
    # compensation.
    struct ToolResultBlock < Block
      getter tool_use_id : String
      getter content : Array(Block)
      getter? is_error : Bool

      def initialize(@tool_use_id : String, @content : Array(Block), @is_error : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "tool_result"
          json.field "tool_use_id", @tool_use_id
          json.field "is_error", @is_error if @is_error
          json.field("content") { json.array { @content.each(&.to_json(json)) } }
        end
      end
    end

    # A provider-run tool call: its own block type here, not a flag, and
    # never dispatched by a client.
    struct ServerToolUseBlock < Block
      getter id : String
      getter name : String
      getter input : String

      def initialize(@id : String, @name : String, @input : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", "server_tool_use"
          json.field "id", @id
          json.field "name", @name
          json.field "input" { json.raw @input }
        end
      end
    end

    # The result type is tool-specific (`web_search_tool_result` and the
    # like), so it is carried as given and kept in `provider_metadata` on
    # export.
    struct ServerToolResultBlock < Block
      getter tool_use_id : String
      getter content : Array(Block)
      getter block_type : String

      def initialize(@tool_use_id : String, @content : Array(Block),
                     @block_type : String = "web_search_tool_result")
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "type", @block_type
          json.field "tool_use_id", @tool_use_id
          json.field("content") { json.array { @content.each(&.to_json(json)) } }
        end
      end
    end

    # Thinking, with a signature that must be replayed unmodified.
    struct ThinkingBlock < Block
      getter thinking : String?
      getter signature : String?
      getter redacted_data : String?

      def initialize(@thinking : String? = nil, @signature : String? = nil,
                     @redacted_data : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          if data = @redacted_data
            json.field "type", "redacted_thinking"
            json.field "data", data
          else
            json.field "type", "thinking"
            json.field "thinking", @thinking || ""
            if value = @signature
              json.field "signature", value
            end
          end
        end
      end
    end

    struct Message
      getter role : String
      getter content : Array(Block)
      # Scaffolding invented to satisfy alternation or the first-user rule.
      # Never serialized; export must discard it.
      getter? synthetic : Bool

      def initialize(@role : String, @content : Array(Block), @synthetic : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "role", @role
          json.field("content") { json.array { @content.each(&.to_json(json)) } }
        end
      end
    end

    # Flat, with the schema under `input_schema` rather than `parameters`.
    struct ToolDeclaration
      getter name : String
      getter description : String?
      getter input_schema : String

      def initialize(@name : String, @description : String?, @input_schema : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "name", @name
          @description.try { |text| json.field "description", text }
          json.field("input_schema") { json.raw @input_schema }
        end
      end
    end

    struct Request
      getter model : String
      getter system : String?
      getter messages : Array(Message)
      getter max_tokens : Int32
      getter tools : Array(ToolDeclaration)
      # Reasoning control comes in two places: a budget in `thinking`, or a
      # rung in `output_config`. The model accepts one or the other, resolved
      # by `Capability::Catalog` before mapping, so at most one is set.
      getter thinking_budget : Int32?
      getter effort : String?
      getter? thinking_disabled : Bool
      # An object with a `type`, where the OpenAI protocols take a bare string.
      getter tool_choice : String?
      # Asks for a frame stream. Set by the adapter through `with_stream`, not
      # by the mapper: streaming is about the call, not the session.
      getter? stream : Bool

      def initialize(@model : String, @messages : Array(Message),
                     @max_tokens : Int32, @system : String? = nil,
                     @tools : Array(ToolDeclaration) = [] of ToolDeclaration,
                     @thinking_budget : Int32? = nil,
                     @effort : String? = nil,
                     @thinking_disabled : Bool = false,
                     @tool_choice : String? = nil,
                     @stream : Bool = false)
      end

      # The same request, streamed. A copy rather than a setter, since a setter
      # on a struct edits whichever copy the caller holds.
      def with_stream(value : Bool) : Request
        Request.new(@model, @messages, @max_tokens, @system, @tools,
          @thinking_budget, @effort, @thinking_disabled, @tool_choice, value)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "model", @model
          # Required here, unlike on the other protocols.
          json.field "max_tokens", @max_tokens
          if text = @system
            json.field "system", text
          end
          json.field("messages") { json.array { @messages.each(&.to_json(json)) } }
          # Emitted only when true, so unstreamed bodies match their recorded
          # transcripts.
          json.field "stream", true if @stream
          unless @tools.empty?
            json.field("tools") { json.array { @tools.each(&.to_json(json)) } }
          end
          @tool_choice.try do |choice|
            json.field("tool_choice") { json.object { json.field "type", choice } }
          end
          if budget = @thinking_budget
            json.field("thinking") do
              json.object do
                json.field "type", "enabled"
                json.field "budget_tokens", budget
              end
            end
          elsif @thinking_disabled
            json.field("thinking") { json.object { json.field "type", "disabled" } }
          end
          if level = @effort
            # Outside `thinking`: effort shapes the whole response, thinking or
            # not.
            json.field("output_config") { json.object { json.field "effort", level } }
          end
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
