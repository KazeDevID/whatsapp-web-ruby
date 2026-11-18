# frozen_string_literal: true

require "net/http"
require "json"
require_relative "test_helper"

class WebhookServerTest < Minitest::Test
  def test_webhook_server_endpoints_and_auth
    sock = BaileysRec.make_wa_socket(mode: :memory).connect
    port = 14_567 + rand(1000)
    server = BaileysRec::Automation::WebhookServer.new(
      socket: sock,
      host: "127.0.0.1",
      port: port,
      api_key: "secret-key-123"
    )
    server.start(blocking: false)
    sleep 0.25

    health = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/v1/health"))
    assert_equal "200", health.code
    assert_equal true, JSON.parse(health.body)["ok"]

    # Unauthorized request must return 401
    uri = URI("http://127.0.0.1:#{port}/v1/messages/send")
    req = Net::HTTP::Post.new(uri, { "Content-Type" => "application/json" })
    req.body = JSON.generate({ to: "628123", text: "Hi" })
    unauth = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
    assert_equal "401", unauth.code

    # Authorized interactive send
    i_uri = URI("http://127.0.0.1:#{port}/v1/messages/interactive")
    i_req = Net::HTTP::Post.new(i_uri, {
      "Content-Type" => "application/json",
      "Authorization" => "Bearer secret-key-123"
    })
    i_req.body = JSON.generate({
      to: "081234567890",
      title: "Promo",
      body: "Pick an option",
      buttons: [
        { type: "reply", id: "opt_1", text: "Buy" },
        { type: "otp", code: "991204", text: "Copy OTP" }
      ]
    })
    ok_res = Net::HTTP.start(i_uri.host, i_uri.port) { |h| h.request(i_req) }
    assert_equal "200", ok_res.code
    assert_equal 1, sock.adapter.sent_messages.size
    assert_equal "6281234567890@s.whatsapp.net", sock.adapter.sent_messages.first[:jid]
  ensure
    server&.stop
  end
end
