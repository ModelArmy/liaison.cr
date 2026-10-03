require "./server"
require "./adapters/adapter"
require "./adapters/chat_completions"
require "./adapters/responses"
require "./adapters/anthropic"
require "./adapters/gemini"
require "./adapters/azure/chat_completions"
require "./adapters/azure/responses"

module Liaison
  # A server speaking one protocol, and the vendor whose opaque data it
  # honours. The three are separate: Ollama is one server with three
  # protocols, none its own vendor; OpenRouter fronting Claude is another
  # server whose vendor is Anthropic.
  class Provider
    getter server : Server
    getter adapter : Adapter
    getter default_max_tokens : Int32

    # `vendor` defaults to the protocol's vendor only when the server's name
    # matches it (`anthropic` speaking Anthropic), and otherwise to the
    # server's name, so the profile is narrowed and foreign signatures
    # degrade rather than replay. Set it for a gateway that passes opaque data
    # through untouched; set wrongly, it costs a rejected turn.
    #
    # `reasoning_unit` overrides the catalog, for a deployment name that
    # carries no model identity. `max_tokens_field` applies to Chat
    # Completions only. Raises `ArgumentError` for a field or unit the
    # protocol cannot use.
    def self.for(server : Server, protocol : ProtocolKind, vendor : String? = nil,
                 default_max_tokens : Int32 = Liaison::Protocol::Anthropic::DEFAULT_MAX_TOKENS,
                 reasoning_unit : Capability::ReasoningUnit? = nil,
                 max_tokens_field : Protocol::ChatCompletions::Wire::MaxTokensField? = nil) : Provider
      canonical = case protocol
                  in ProtocolKind::ChatCompletions then Liaison::Protocol::ChatCompletions::METADATA_KEY
                  in ProtocolKind::Responses       then Liaison::Protocol::Responses::METADATA_KEY
                  in ProtocolKind::Anthropic       then Liaison::Protocol::Anthropic::METADATA_KEY
                  in ProtocolKind::Gemini          then Liaison::Protocol::Gemini::METADATA_KEY
                  end

      resolved = vendor || (server.name == canonical ? canonical : server.name)

      if max_tokens_field && !protocol.chat_completions?
        raise ArgumentError.new("max_tokens_field only applies to ChatCompletions, not #{protocol}")
      end

      adapter = case protocol
                in ProtocolKind::ChatCompletions
                  ChatCompletionsAdapter.new(resolved, reasoning_unit,
                    max_tokens_field || Protocol::ChatCompletions::Wire::MaxTokensField::MaxTokens)
                in ProtocolKind::Responses then ResponsesAdapter.new(resolved, reasoning_unit)
                in ProtocolKind::Anthropic then AnthropicAdapter.new(resolved, reasoning_unit)
                in ProtocolKind::Gemini    then GeminiAdapter.new(resolved, reasoning_unit)
                end

      if unit = reasoning_unit
        declared = adapter.profile.reasoning_unit
        unless declared.either? || declared == unit
          raise ArgumentError.new(
            "#{declared} is the reasoning unit #{adapter.profile.provider} spells; " \
            "#{unit} cannot be requested of it")
        end
      end

      new(server, adapter, default_max_tokens)
    end

    # Azure OpenAI's Chat Completions or Responses surface: OpenAI's wire shape
    # and `Profile`, with Azure's path and `api-key` header. Raises
    # `ArgumentError` for Anthropic or Gemini, which Azure does not serve, or
    # for `max_tokens_field` on Responses. `api_version` has no default, since
    # Azure's dated versions drift.
    def self.for_azure(server : Server, protocol : ProtocolKind, api_version : String,
                       vendor : String? = nil,
                       default_max_tokens : Int32 = Liaison::Protocol::Anthropic::DEFAULT_MAX_TOKENS,
                       reasoning_unit : Capability::ReasoningUnit? = nil,
                       max_tokens_field : Protocol::ChatCompletions::Wire::MaxTokensField? = nil) : Provider
      canonical = case protocol
                  in ProtocolKind::ChatCompletions then Liaison::Protocol::ChatCompletions::METADATA_KEY
                  in ProtocolKind::Responses       then Liaison::Protocol::Responses::METADATA_KEY
                  in ProtocolKind::Anthropic, ProtocolKind::Gemini
                    raise ArgumentError.new("Azure OpenAI does not serve #{protocol} — only ChatCompletions and Responses")
                  end
      resolved = vendor || (server.name == canonical ? canonical : server.name)

      if max_tokens_field && !protocol.chat_completions?
        raise ArgumentError.new("max_tokens_field only applies to ChatCompletions, not #{protocol}")
      end

      adapter = case protocol
                in ProtocolKind::ChatCompletions
                  AzureChatCompletionsAdapter.new(api_version, resolved, reasoning_unit,
                    max_tokens_field || Protocol::ChatCompletions::Wire::MaxTokensField::MaxTokens)
                in ProtocolKind::Responses
                  AzureResponsesAdapter.new(api_version, resolved, reasoning_unit)
                in ProtocolKind::Anthropic, ProtocolKind::Gemini
                  raise ArgumentError.new("Azure OpenAI does not serve #{protocol} — only ChatCompletions and Responses")
                end

      new(server, adapter, default_max_tokens)
    end

    def initialize(@server : Server, @adapter : Adapter,
                   @default_max_tokens : Int32 = Liaison::Protocol::Anthropic::DEFAULT_MAX_TOKENS)
    end

    # What this deployment can express after vendor narrowing: what a handoff
    # to it will lose.
    def profile : Capability::Profile
      @adapter.narrowed
    end

    # The same, narrowed for one model, which settles the reasoning unit on
    # the two protocols that spell both.
    def profile(model : String) : Capability::Profile
      @adapter.narrowed(model)
    end

    def vendor : String?
      @adapter.vendor
    end
  end
end
