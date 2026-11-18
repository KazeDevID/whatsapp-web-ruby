# frozen_string_literal: true

require_relative "test_helper"

class AutomationTest < Minitest::Test
  def test_router_dispatches_commands_patterns_and_buttons
    sock = WhatsappWebRuby.make_wa_socket(mode: :memory).connect
    router = WhatsappWebRuby::Automation::Router.new(prefix: "!")
    log = []

    router.use do |ctx, next_fn|
      log << "mw:#{ctx.sender}"
      next_fn.call
    end

    router.on_command("ping") { |ctx| ctx.reply("pong") }
    router.on_button("buy_*") { |ctx| ctx.reply("buying:#{ctx.button_id}") }
    router.attach(sock)

    sock.ev.emit(:messages_upsert, {
      "messages" => [
        { "key" => { "remoteJid" => "628111@s.whatsapp.net", "id" => "1", "fromMe" => false }, "message" => { "conversation" => "!ping" } },
        { "key" => { "remoteJid" => "628111@s.whatsapp.net", "id" => "2", "fromMe" => false }, "message" => { "buttonsResponseMessage" => { "selectedButtonId" => "buy_vip", "selectedDisplayText" => "VIP" } } }
      ]
    })

    assert_equal 2, sock.adapter.sent_messages.size
    assert_equal({ text: "pong" }, sock.adapter.sent_messages[0][:content])
    assert_equal({ text: "buying:buy_vip" }, sock.adapter.sent_messages[1][:content])
    assert_equal 2, log.size
  end

  def test_dispatcher_idempotency_and_retries
    attempts = 0
    flaky_adapter = Class.new(WhatsappWebRuby::Transport::MemoryAdapter) do
      define_method(:send_message) do |jid, content, options = {}|
        attempts += 1
        raise WhatsappWebRuby::TimeoutError, "temporary timeout" if attempts == 1

        super(jid, content, options)
      end
    end.new

    sock = WhatsappWebRuby.make_wa_socket(mode: :memory, adapter: flaky_adapter, max_retries: 0).connect
    dispatcher = WhatsappWebRuby::Automation::Dispatcher.new(
      socket: sock,
      per_jid_interval: 0.01,
      max_attempts: 3,
      base_backoff: 0.01
    ).start

    j1 = dispatcher.enqueue(jid: "628999", content: { text: "Hello" }, idempotency_key: "key-1")
    j2 = dispatcher.enqueue(jid: "628999", content: { text: "Hello" }, idempotency_key: "key-1")

    assert_equal j1.id, j2.id
    assert dispatcher.wait_until_empty(timeout: 5)
    dispatcher.stop

    assert_equal :sent, j1.status
    assert_equal 2, j1.attempts
    assert_equal 1, dispatcher.stats[:sent]
    assert_equal 1, dispatcher.stats[:deduplicated]
  end

  def test_multi_file_auth_state_persistence
    dir = File.join("/tmp", "whatsapp_web_ruby_auth_test_#{Process.pid}")
    state = WhatsappWebRuby.use_multi_file_auth_state(dir)
    state.save_creds({ "me" => { "id" => "628123@s.whatsapp.net" } })
    state.set_keys("session" => { "1" => { "key" => "abc" } })

    reloaded = WhatsappWebRuby.use_multi_file_auth_state(dir)
    assert_equal "628123@s.whatsapp.net", reloaded.creds.dig("me", "id")
    assert_equal({ "1" => { "key" => "abc" } }, reloaded.get_keys("session", ["1"]))
    reloaded.clear!
  end

  def test_bridge_adapter_event_listener_can_call_rpc_without_deadlock
    dir = File.join("/tmp", "whatsapp_web_ruby_bridge_test_#{Process.pid}_#{rand(10_000)}")
    FileUtils.mkdir_p(dir)
    mock_worker = File.join(dir, "mock_worker.mjs")
    File.write(mock_worker, <<~JS)
      import readline from "node:readline";
      const rl = readline.createInterface({ input: process.stdin });
      rl.on("line", (line) => {
        const req = JSON.parse(line);
        if (req.method === "init") {
          process.stdout.write(JSON.stringify({ id: req.id, result: { status: "ok" } }) + "\\n");
          process.stdout.write(JSON.stringify({ event: "connection.update", data: { connection: "open" } }) + "\\n");
          process.stdout.write(JSON.stringify({
            event: "messages.upsert",
            data: { type: "notify", messages: [{ key: { remoteJid: "628111@s.whatsapp.net", id: "IN_1", fromMe: false }, message: { conversation: "!ping" } }] }
          }) + "\\n");
        } else if (req.method === "sendMessage") {
          process.stdout.write(JSON.stringify({ id: req.id, result: { key: { id: "OUT_1", remoteJid: req.params.jid, fromMe: true } } }) + "\\n");
        } else if (req.method === "shutdown") {
          process.stdout.write(JSON.stringify({ id: req.id, result: { shutdown: true } }) + "\\n");
          process.exit(0);
        }
      });
    JS

    adapter = WhatsappWebRuby::Transport::BridgeAdapter.new(worker_path: mock_worker, timeout: 3, auto_restart: false)
    sock = WhatsappWebRuby.make_wa_socket(mode: :bridge, adapter: adapter)
    replied = Queue.new

    sock.ev.on(:messages_upsert) do |upsert|
      msg = WhatsappWebRuby.serialize_message(upsert["messages"].first)
      res = sock.send_message(msg[:from], { text: "pong" })
      replied.push(res)
    end

    sock.connect
    result = replied.pop
    assert_equal "OUT_1", result.dig("key", "id")
    assert sock.sent_by_me?("OUT_1")
  ensure
    sock&.end_connection
    FileUtils.rm_rf(dir)
  end
end
