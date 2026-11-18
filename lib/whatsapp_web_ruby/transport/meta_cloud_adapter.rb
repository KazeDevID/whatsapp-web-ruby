# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module WhatsappWebRuby
  module Transport
    # Pure-Ruby Meta WhatsApp Business Cloud API v21.0 HTTP Adapter.
    class MetaCloudAdapter
      BASE_GRAPH_URL = "https://graph.facebook.com"

      def initialize(phone_number_id:, access_token:, api_version: "v21.0", max_retries: 3, timeout: 15)
        raise ConfigurationError, "phone_number_id is required" if phone_number_id.to_s.empty?
        raise ConfigurationError, "access_token is required" if access_token.to_s.empty?

        @phone_number_id = phone_number_id.to_s
        @access_token = access_token.to_s
        @api_version = api_version.to_s
        @max_retries = max_retries
        @timeout = timeout
        @connected = false
      end

      def connect(_emitter)
        @connected = true
        { status: "open", mode: :cloud_api, phone_number_id: @phone_number_id }
      end

      def disconnect
        @connected = false
      end

      def connected?
        @connected
      end

      def send_message(jid, content, _options = {})
        recipient = Utils::Jid.sanitize_whatsapp_number(jid)
        payload = if content.is_a?(Hash) && content[:messaging_product] == "whatsapp"
                    content.merge(to: recipient)
                  else
                    Utils::CloudApi.to_cloud_api_message(content, recipient)
                  end

        post_json(payload)
      end

      def send_template(to, template_name, language_code: "en_US", components: [])
        post_json(
          messaging_product: "whatsapp",
          recipient_type: "individual",
          to: Utils::Jid.sanitize_whatsapp_number(to),
          type: "template",
          template: {
            name: template_name.to_s,
            language: { code: language_code.to_s },
            components: components
          }
        )
      end

      def post_json(payload)
        uri = URI("#{BASE_GRAPH_URL}/#{@api_version}/#{@phone_number_id}/messages")
        attempt = 0

        loop do
          attempt += 1
          response = execute_http(uri, payload)
          body = parse_json(response.body)

          if response.is_a?(Net::HTTPSuccess) && !body["error"]
            return {
              "status" => "sent",
              "provider" => "meta_cloud_api",
              "message_id" => body.dig("messages", 0, "id"),
              "raw" => body
            }
          end

          status = response.code.to_i
          if retryable?(status) && attempt <= @max_retries
            sleep(backoff_seconds(attempt, response["Retry-After"]))
            next
          end

          diag = Utils::CloudApi.diagnose_meta_cloud_api_error(
            body["error"] || { code: status, message: response.message }
          )

          if status == 429
            raise RateLimitError.new(
              "Meta Cloud API Rate Limit: #{diag[:title]}",
              retry_after: response["Retry-After"]&.to_i,
              status_code: status,
              code: diag[:code],
              diagnostics: diag
            )
          end

          raise TransportError.new(
            "Meta Cloud API Error [#{diag[:code]}]: #{diag[:title]} - #{diag[:explanation]}",
            status_code: status,
            code: diag[:code],
            diagnostics: diag
          )
        end
      end

      private

      def execute_http(uri, payload)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = @timeout
        http.read_timeout = @timeout

        req = Net::HTTP::Post.new(uri.request_uri)
        req["Authorization"] = "Bearer #{@access_token}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(payload)

        http.request(req)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        raise TimeoutError, "Meta Cloud API request timed out: #{e.message}"
      end

      def parse_json(raw)
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      def retryable?(status)
        status == 429 || status >= 500
      end

      def backoff_seconds(attempt, retry_after_header)
        return retry_after_header.to_f if retry_after_header && retry_after_header.to_f.positive?

        (0.5 * (2**(attempt - 1))) + rand(0.0..0.25)
      end
    end
  end
end
