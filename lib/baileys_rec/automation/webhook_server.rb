# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "webrick"

module BaileysRec
  module Automation
    # Built-in Pure-Ruby REST API & Webhook Server for stable WhatsApp message automation.
    class WebhookServer
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
      end

      def start(blocking: true)
        @server = WEBrick::HTTPServer.new(
          BindAddress: @host,
          Port: @port,
          Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN),
          AccessLog: []
        )

        mount_routes
        attach_incoming_webhooks if @webhook_url

        if blocking
          trap("INT") { stop }
          trap("TERM") { stop }
          @server.start
        else
          Thread.new { @server.start }
        end
        self
      end

      def stop
        @server&.shutdown
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
          req["X-BaileysRec-Signature"] = "sha256=#{sig}"
        end
        req.body = body
        http.request(req)
        true
      rescue StandardError => e
        warn "[BaileysRec::WebhookServer] webhook dispatch error: #{e.message}"
        false
      end

      private

      def mount_routes
        @server.mount_proc "/v1/health" do |_req, res|
          json_response(res, 200, {
            ok: true,
            version: BaileysRec::VERSION,
            connected: @socket.connected?,
            mode: @socket.mode,
            queue: @dispatcher.stats
          })
        end

        @server.mount_proc "/v1/messages/send" do |req, res|
          handle_authenticated(req, res) do |body|
            jid = body.fetch("to") { raise ValidationError, "'to' is required" }
            content = body["message"] || { text: body.fetch("text") { raise ValidationError, "'text' or 'message' is required" } }
            enqueue_or_send(res, jid, content, body)
          end
        end

        @server.mount_proc "/v1/messages/interactive" do |req, res|
          handle_authenticated(req, res) do |body|
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
        end

        @server.mount_proc "/v1/messages/cloud-api" do |req, res|
          handle_authenticated(req, res) do |body|
            jid = body.fetch("to") { raise ValidationError, "'to' is required" }
            converted = @socket.mode == :cloud_api ? body : Utils::CloudApi.from_cloud_api_message(body)
            enqueue_or_send(res, jid, converted, body)
          end
        end

        @server.mount_proc "/v1/session/pairing-code" do |req, res|
          handle_authenticated(req, res) do |body|
            phone = body.fetch("phone_number") { raise ValidationError, "'phone_number' is required" }
            result = @socket.request_pairing_code(phone, body["custom_code"])
            json_response(res, 200, { ok: true, data: result })
          end
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

      def handle_authenticated(req, res)
        if req.request_method != "POST"
          return json_response(res, 405, { ok: false, error: "Method not allowed" })
        end

        if @api_key && !@api_key.empty?
          auth_header = req["Authorization"].to_s
          expected = "Bearer #{@api_key}"
          unless auth_header == expected
            return json_response(res, 401, { ok: false, error: "Unauthorized" })
          end
        end

        body = JSON.parse(req.body.to_s.empty? ? "{}" : req.body)
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
