require "./session"

module Liaison::MPSH
  # Maps MPSH call ids to one provider's call ids and back, for one
  # conversation. A mapper and its exporter share one, so a call read back from
  # a reply recovers the MPSH id it was sent under.
  class CallIdTable
    getter provider : String

    def initialize(@provider : String)
      @to_provider = {} of String => String
      @to_mpsh = {} of String => String
    end

    def bind(mpsh_id : String, provider_id : String) : Nil
      @to_provider[mpsh_id] = provider_id
      @to_mpsh[provider_id] = mpsh_id
    end

    def provider_id(mpsh_id : String) : String?
      @to_provider[mpsh_id]?
    end

    # Export direction: an unseen provider id gets a freshly minted MPSH id.
    def mpsh_id(provider_id : String) : String
      @to_mpsh[provider_id]? || begin
        minted = Ids.call_id
        bind(minted, provider_id)
        minted
      end
    end

    # The key Gemini's mapper binds in place of a provider id, which Gemini
    # lacks: the call's name and its ordinal.
    def positional_key(name : String, ordinal : Int32) : String
      "#{name}##{ordinal}"
    end
  end
end
