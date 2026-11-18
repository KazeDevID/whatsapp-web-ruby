# frozen_string_literal: true

module WhatsappWebRuby
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class ConnectionError < Error; end

  class TransportError < Error
    attr_reader :status_code, :code, :diagnostics

    def initialize(message, status_code: nil, code: nil, diagnostics: nil)
      super(message)
      @status_code = status_code
      @code = code
      @diagnostics = diagnostics
    end
  end

  class TimeoutError < TransportError; end

  class ValidationError < Error; end

  class RateLimitError < TransportError
    attr_reader :retry_after

    def initialize(message = "Rate limit exceeded", retry_after: nil, **kwargs)
      super(message, **kwargs)
      @retry_after = retry_after
    end
  end
end
