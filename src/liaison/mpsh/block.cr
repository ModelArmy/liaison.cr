require "./meta"
require "./payload"

module Liaison::MPSH
  # Discriminator for capability lookups, annotations and the archive. Branch
  # on the `Block` union with `case ... in`, not on this.
  enum BlockKind
    Text
    Image
    Audio
    Document
    ToolCall
    ToolResult
    Reasoning
    Refusal
  end

  # Implemented by every block. Blocks share this module rather than a
  # superclass; `Block` below is their closed union.
  module BlockRole
    include ProviderScoped

    abstract def kind : BlockKind
  end

  # Blocks carrying binary payloads. Where a target cannot carry one, a
  # `text_fallback` lets it degrade to text; without one it is refused.
  module BinaryBlock
    include BlockRole

    abstract def payload : Payload
    abstract def text_fallback : String?

    def media_type : String
      payload.media_type
    end
  end

  class TextBlock
    include BlockRole
    getter text : String

    def initialize(@text : String)
    end

    def kind : BlockKind
      BlockKind::Text
    end
  end

  class ImageBlock
    include BinaryBlock
    getter payload : Payload
    getter text_fallback : String?
    getter name : String?

    def initialize(@payload : Payload, @text_fallback : String? = nil, @name : String? = nil)
    end

    def kind : BlockKind
      BlockKind::Image
    end
  end

  class AudioBlock
    include BinaryBlock
    getter payload : Payload
    # Typically a transcript.
    getter text_fallback : String?
    getter name : String?

    def initialize(@payload : Payload, @text_fallback : String? = nil, @name : String? = nil)
    end

    def kind : BlockKind
      BlockKind::Audio
    end
  end

  class DocumentBlock
    include BinaryBlock
    getter payload : Payload
    getter name : String
    getter text_fallback : String?

    def initialize(@payload : Payload, @name : String, @text_fallback : String? = nil)
    end

    def kind : BlockKind
      BlockKind::Document
    end
  end

  # A tool call, assistant-side. `call_id` is minted by MPSH (`Ids.call_id`);
  # provider ids live in a `CallIdTable`, never here.
  #
  # `arguments` is stored parsed. Serializing an object cannot fail and parsing
  # a string can, so parsing happens once, on export.
  class ToolCallBlock
    include BlockRole
    getter call_id : String
    getter name : String
    getter arguments : Object
    getter? server_executed : Bool

    def initialize(@call_id : String, @name : String, @arguments : Object = Object.new,
                   @server_executed : Bool = false)
    end

    def kind : BlockKind
      BlockKind::ToolCall
    end
  end

  # A tool's result, user-side. `content` is a block list, so a tool can return
  # images.
  #
  # `is_error` says the tool reported failure, and is sent to the provider.
  # `exception` records that dispatch itself raised; only `Archive` stores it,
  # so a result for a tool that raised sets both.
  class ToolResultBlock
    include BlockRole
    getter call_id : String
    getter content : Array(Block)
    getter? is_error : Bool
    getter exception : String?
    getter? server_executed : Bool

    def initialize(@call_id : String, @content : Array(Block) = [] of Block,
                   @is_error : Bool = false, @exception : String? = nil,
                   @server_executed : Bool = false)
    end

    def kind : BlockKind
      BlockKind::ToolResult
    end

    # Whether every content block is text.
    def text_only? : Bool
      content.all?(TextBlock)
    end
  end

  # `redacted: true` with no text records that reasoning happened and the
  # provider withheld it, a fact kept across a handoff. The opaque payload
  # lives in `provider_metadata`, which a foreign protocol does not read.
  class ReasoningBlock
    include BlockRole
    getter text : String?
    getter? redacted : Bool

    def initialize(@text : String? = nil, @redacted : Bool = false)
    end

    def kind : BlockKind
      BlockKind::Reasoning
    end
  end

  # Some protocols emit refusal on a channel distinct from text.
  class RefusalBlock
    include BlockRole
    getter reason : String?

    def initialize(@reason : String? = nil)
    end

    def kind : BlockKind
      BlockKind::Refusal
    end
  end

  # The closed union of block types, so `case block; in TextBlock ...` is
  # checked for exhaustiveness.
  alias Block = TextBlock | ImageBlock | AudioBlock | DocumentBlock |
                ToolCallBlock | ToolResultBlock | ReasoningBlock | RefusalBlock
end
