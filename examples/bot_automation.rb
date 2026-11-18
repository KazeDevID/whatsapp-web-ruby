# frozen_string_literal: true

require_relative "../lib/baileys_rec"

sock = BaileysRec.make_wa_socket(mode: :memory).connect

dispatcher = BaileysRec::Automation::Dispatcher.new(
  socket: sock,
  per_jid_interval: 0.2,
  max_attempts: 3
).start

router = BaileysRec::Automation::Router.new(prefix: "!")

router.use do |ctx, next_fn|
  puts "[LOG] Incoming from #{ctx.sender}: #{ctx.body}"
  next_fn.call
end

router.on_command("promo") do |ctx|
  card1 = BaileysRec::Button.new(sock)
                            .set_title("Pro Plan")
                            .set_body("Unlimited automated messages")
                            .add_reply("Select Pro", "plan_pro")

  card2 = BaileysRec::Button.new(sock)
                            .set_title("Enterprise")
                            .set_body("Dedicated multi-device cluster")
                            .add_url("Contact Sales", "https://example.com")

  BaileysRec::Carousel.new(sock)
                      .set_title("Available Plans")
                      .set_body("Swipe to compare packages")
                      .add_card([card1, card2])
                      .send(ctx.jid)
end

router.on_button("plan_*") do |ctx|
  dispatcher.enqueue(
    jid: ctx.jid,
    content: { text: "Selected plan: #{ctx.button_id}" },
    idempotency_key: "sel-#{ctx.message[:id]}"
  )
end

router.attach(sock)

sock.ev.emit(:messages_upsert, {
  "messages" => [
    {
      "key" => { "remoteJid" => "6281234567890@s.whatsapp.net", "id" => "M1", "fromMe" => false },
      "pushName" => "Demo User",
      "message" => { "conversation" => "!promo" }
    }
  ]
})

dispatcher.wait_until_empty
dispatcher.stop
puts "Dispatched messages: #{sock.adapter.sent_messages.size}"
