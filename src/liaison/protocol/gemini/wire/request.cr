require "json"

module Liaison::Protocol::Gemini
  # The request half of the `generateContent` wire form. The assistant role
  # is `model`, every message is a `{role, parts}` object with no string
  # shorthand, the model goes in the URL path, and generation settings nest
  # in `generationConfig`. A function call carries no identifier; calls and
  # responses pair by name and order.
  module Wire
    abstract struct Part
      abstract def to_json(json : JSON::Builder)
    end

    struct TextPart < Part
      getter text : String

      def initialize(@text : String)
      end

      def to_json(json : JSON::Builder)
        json.object { json.field "text", @text }
      end
    end

    # `inline_data` keeps mime type and base64 separate, as MPSH stores them.
    struct InlineDataPart < Part
      getter mime_type : String
      getter base64 : String

      def initialize(@mime_type : String, @base64 : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "inline_data" do
            json.object do
              json.field "mime_type", @mime_type
              json.field "data", @base64
            end
          end
        end
      end
    end

    # Carries no id, and none may be invented: an unknown key may be
    # rejected. `thought_signature` sits beside `functionCall` on the same
    # part; Gemini 3 requires it on replay and 2.5 does not (recorded in
    # `spec/live/gemini_spec.cr`).
    struct FunctionCallPart < Part
      getter name : String
      getter args : String
      getter thought_signature : String?

      def initialize(@name : String, @args : String, @thought_signature : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "functionCall" do
            json.object do
              json.field "name", @name
              json.field "args" { json.raw @args }
            end
          end
          @thought_signature.try { |value| json.field "thoughtSignature", value }
        end
      end
    end

    # Paired to its call by `name`, and by ordering where a name repeats.
    struct FunctionResponsePart < Part
      getter name : String
      getter response : String

      def initialize(@name : String, @response : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "functionResponse" do
            json.object do
              json.field "name", @name
              json.field "response" { json.raw @response }
            end
          end
        end
      end
    end

    # A thought part. Returned only when thoughts are requested, possibly with
    # a signature that must be replayed unmodified.
    struct ThoughtPart < Part
      getter text : String?
      getter signature : String?

      def initialize(@text : String? = nil, @signature : String? = nil)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "thought", true
          json.field "text", @text || ""
          if value = @signature
            json.field "thoughtSignature", value
          end
        end
      end
    end

    # The assistant role is the string `model`.
    struct Content
      getter role : String
      getter parts : Array(Part)
      getter? synthetic : Bool

      def initialize(@role : String, @parts : Array(Part), @synthetic : Bool = false)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "role", @role
          json.field("parts") { json.array { @parts.each(&.to_json(json)) } }
        end
      end
    end

    # Doubly nested: declarations sit in `functionDeclarations`, inside an
    # entry of `tools`, which also holds provider-run tools such as code
    # execution.
    struct ToolDeclaration
      getter name : String
      getter description : String?
      getter parameters : String

      def initialize(@name : String, @description : String?, @parameters : String)
      end

      def to_json(json : JSON::Builder)
        json.object do
          json.field "name", @name
          @description.try { |text| json.field "description", text }
          # Emitted as given. Gemini accepts a subset of OpenAPI schema, so a
          # schema valid elsewhere may be rejected here; it is not rewritten.
          json.field("parameters") { json.raw @parameters }
        end
      end
    end

    # The model is carried for the URL path and is not written by `to_json`.
    struct Request
      getter model : String
      getter contents : Array(Content)
      getter system_instruction : String?
      getter tools : Array(ToolDeclaration)
      getter max_output_tokens : Int32?
      # Under `generationConfig.thinkingConfig`. Budget and level must not
      # both be set, so the unit is resolved per model before mapping. A budget
      # of 0 disables thinking; -1 asks for dynamic thinking.
      getter thinking_budget : Int32?
      getter thinking_level : String?
      # Sent as `toolConfig.functionCallingConfig.mode`, top-level beside
      # `tools`.
      getter tool_mode : String?

      def initialize(@model : String, @contents : Array(Content),
                     @system_instruction : String? = nil,
                     @tools : Array(ToolDeclaration) = [] of ToolDeclaration,
                     @max_output_tokens : Int32? = nil,
                     @thinking_budget : Int32? = nil,
                     @thinking_level : String? = nil,
                     @tool_mode : String? = nil)
      end

      def path : String
        "models/#{@model}:generateContent"
      end

      def to_json(json : JSON::Builder)
        json.object do
          if text = @system_instruction
            # A content object, not a bare string.
            json.field "systemInstruction" do
              json.object do
                json.field("parts") do
                  json.array { json.object { json.field "text", text } }
                end
              end
            end
          end
          json.field("contents") { json.array { @contents.each(&.to_json(json)) } }
          unless @tools.empty?
            json.field("tools") do
              json.array do
                json.object do
                  json.field("functionDeclarations") do
                    json.array { @tools.each(&.to_json(json)) }
                  end
                end
              end
            end
          end
          @tool_mode.try do |mode|
            json.field("toolConfig") do
              json.object do
                json.field("functionCallingConfig") { json.object { json.field "mode", mode } }
              end
            end
          end
          # Generation settings share one `generationConfig` object, written
          # once.
          cap = @max_output_tokens
          budget = @thinking_budget
          level = @thinking_level
          if cap || budget || level
            json.field("generationConfig") do
              json.object do
                cap.try { |value| json.field "maxOutputTokens", value }
                if budget || level
                  json.field("thinkingConfig") do
                    json.object do
                      budget.try { |value| json.field "thinkingBudget", value }
                      level.try { |value| json.field "thinkingLevel", value }
                      # Without it, thinking happens and is billed, but neither
                      # thought text nor the signatures a later turn replays
                      # come back. Sent whenever thinking is configured.
                      json.field "includeThoughts", true
                    end
                  end
                end
              end
            end
          end
        end
      end

      def to_json : String
        String.build { |io| JSON.build(io) { |json| to_json(json) } }
      end
    end
  end
end
