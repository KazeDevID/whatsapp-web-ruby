# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "socket"
require "uri"

module WhatsappWebRuby
  module Automation
    # Lightweight HTTP Response wrapper compatible with WebhookServer route handlers.
    class HttpResponse
      attr_accessor :status, :body
      attr_reader :headers

      def initialize
        @status = 200
        @headers = { "Content-Type" => "application/json" }
        @body = ""
      end

      def []=(key, val)
        @headers[key] = val
      end
    end

    # Built-in Pure-Ruby TCPServer HTTP REST API & Webhook Server (zero external gems, Ruby 3.0-4.0+ compatible).
    class WebhookServer
      STATUS_TEXT = {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error"
      }.freeze

      def initialize(socket:, dispatcher: nil, host: "0.0.0.0", port: 4567,
                     api_key: nil, webhook_url: nil, webhook_secret: nil)
        @socket = socket
        @dispatcher = dispatcher || Dispatcher.new(socket: socket).start
        @host = host
        @port = port.to_i
        @api_key = api_key
        @webhook_url = webhook_url
        @webhook_secret = webhook_secret
        @server = nil
        @running = false
        @accept_thread = nil
      end

      def start(blocking: true)
        @server = TCPServer.new(@host, @port)
        @running = true
        attach_incoming_webhooks if @webhook_url

        if blocking
          trap("INT") { @running = false }
          trap("TERM") { @running = false }
          @accept_thread = Thread.new { accept_loop }
          sleep 0.2 while @running
          stop
        else
          @accept_thread = Thread.new { accept_loop }
        end
        self
      end

      def stop
        @running = false
        begin
          @server&.close unless @server&.closed?
        rescue StandardError
          nil
        end
        @accept_thread&.join(2)
        @dispatcher.stop(drain: false)
      end

      # Signs and dispatches an outgoing webhook event with HMAC-SHA256.
      def emit_webhook(event_name, payload)
        return false unless @webhook_url

        uri = URI(@webhook_url)
        body = JSON.generate({
          event: event_name,
          timestamp: Time.now.to_i,
          data: payload
        })

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 5
        http.read_timeout = 10

        req = Net::HTTP::Post.new(uri.request_uri)
        req["Content-Type"] = "application/json"
        if @webhook_secret && !@webhook_secret.empty?
          sig = OpenSSL::HMAC.hexdigest("SHA256", @webhook_secret, body)
          req["X-WhatsappWebRuby-Signature"] = "sha256=#{sig}"
        end
        req.body = body
        http.request(req)
        true
      rescue StandardError => e
        warn "[WhatsappWebRuby::WebhookServer] webhook dispatch error: #{e.message}"
        false
      end

      private

      def accept_loop
        while @running
          client = @server.accept
          Thread.new(client) { |conn| handle_connection(conn) }
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def handle_connection(conn)
        request_line = conn.gets
        return unless request_line

        method, full_path, = request_line.strip.split(" ", 3)
        path = full_path.to_s.split("?", 2).first

        headers = {}
        while (line = conn.gets)
          line = line.chomp
          break if line.empty?

          k, v = line.split(":", 2)
          headers[k.strip.downcase] = v.strip if k && v
        end

        content_length = headers["content-length"].to_i
        raw_body = content_length.positive? ? conn.read(content_length).to_s : ""

        res = HttpResponse.new
        route_request(method, path, headers, raw_body, res)

        status_text = STATUS_TEXT.fetch(res.status, "OK")
        payload = res.body.to_s
        conn.write("HTTP/1.1 #{res.status} #{status_text}\r\n")
        conn.write("Content-Type: #{res.headers['Content-Type']}\r\n")
        conn.write("Content-Length: #{payload.bytesize}\r\n")
        conn.write("Connection: close\r\n\r\n")
        conn.write(payload)
      rescue StandardError => e
        warn "[WhatsappWebRuby::WebhookServer] connection error: #{e.message}"
      ensure
        conn&.close unless conn&.closed?
      end

      def route_request(method, path, headers, raw_body, res)
        case path
        when "/v1/health"
          json_response(res, 200, {
            ok: true,
            version: WhatsappWebRuby::VERSION,
            connected: @socket.connected?,
            mode: @socket.mode,
            queue: @dispatcher.stats
          })
        when "/v1/messages/send"
          handle_authenticated(method, headers, raw_body, res) do |body|
            jid = body.fetch("to") { raise ValidationError, "'to' is required" }
            content = body["message"] || { text: body.fetch("text") { raise ValidationError, "'text' or 'message' is required" } }
            enqueue_or_send(res, jid, content, body)
          end
        when "/v1/messages/interactive"
          handle_authenticated(method, headers, raw_body, res) do |body|
            jid = body.fetch("to") { raise ValidationError, "'to' is required" }
            btn = Builders::Button.new(@socket)
            btn.set_title(body["title"]) if body["title"]
            btn.set_subtitle(body["subtitle"]) if body["subtitle"]
            btn.set_body(body["body"] || body["text"] || " ")
            btn.set_footer(body["footer"]) if body["footer"]
            btn.set_image(body["image"]) if body["image"]

            Array(body["buttons"]).each do |b|
              case b["type"]
              when "url" then btn.add_url(b["text"], b["url"], b["webview"])
              when "copy" then btn.add_copy(b["text"], b["code"])
              when "otp" then btn.add_otp(b["code"], b["text"] || "Copy Code")
              when "call" then btn.add_call(b["text"], b["phone"])
              when "flow" then btn.add_flow(b["flow_id"], b)
              else btn.add_reply(b["text"] || "Select", b["id"] || "btn_1")
              end
            end

            enqueue_or_send(res, jid, btn.build, body)
          end
        when "/v1/messages/cloud-api"
          handle_authenticated(method, headers, raw_body, res) do |body|
            jid = body.fetch("to") { raise ValidationError, "'to' is required" }
            converted = @socket.mode == :cloud_api ? body : Utils::CloudApi.from_cloud_api_message(body)
            enqueue_or_send(res, jid, converted, body)
          end
        when "/v1/session/pairing-code"
          handle_authenticated(method, headers, raw_body, res) do |body|
            phone = body.fetch("phone_number") { raise ValidationError, "'phone_number' is required" }
            result = @socket.request_pairing_code(phone, body["custom_code"])
            json_response(res, 200, { ok: true, data: result })
          end
        else
          json_response(res, 404, { ok: false, error: "Not found" })
        end
      end

      def attach_incoming_webhooks
        @socket.ev.on(:messages_upsert) do |upsert|
          Thread.new { emit_webhook("messages.upsert", upsert) }
        end
        @socket.ev.on(:connection_update) do |update|
          Thread.new { emit_webhook("connection.update", update) }
        end
      end

      def enqueue_or_send(res, jid, content, body)
        if body["async"]
          job = @dispatcher.enqueue(
            jid: jid,
            content: content,
            idempotency_key: body["idempotency_key"],
            priority: (body["priority"] || "normal").to_sym
          )
          json_response(res, 202, { ok: true, queued: true, job_id: job.id, status: job.status })
        else
          result = @socket.send_message(jid, content)
          json_response(res, 200, { ok: true, result: result })
        end
      end

      def handle_authenticated(method, headers, raw_body, res)
        if method != "POST"
          return json_response(res, 405, { ok: false, error: "Method not allowed" })
        end

        if @api_key && !@api_key.empty?
          auth_header = headers["authorization"].to_s
          expected = "Bearer #{@api_key}"
          unless auth_header == expected
            return json_response(res, 401, { ok: false, error: "Unauthorized" })
          end
        end

        body = JSON.parse(raw_body.empty? ? "{}" : raw_body)
        yield(body)
      rescue ValidationError => e
        json_response(res, 400, { ok: false, error: e.message })
      rescue JSON::ParserError
        json_response(res, 400, { ok: false, error: "Invalid JSON body" })
      rescue StandardError => e
        json_response(res, 500, { ok: false, error: e.message })
      end

      def json_response(res, status, data)
        res.status = status
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(data)
      end
    end
  end
end
