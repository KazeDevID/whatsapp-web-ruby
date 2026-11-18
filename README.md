# whatsapp-web-ruby

WhatsApp Bot & Automation Library for Ruby (`>= 3.0`) with Multi-Device Signal E2EE, Interactive Buttons, Swipeable Carousels, WhatsApp Flows v3.1, AI Rich Messages, Newsletter/Channels, and Meta Cloud API v21.0 parity.

## Features

- **Dual Stable Transport Architecture**:
  - `:bridge` mode — Connects to the bundled `baileys-rec` Multi-Device Signal E2EE Node.js worker over resilient NDJSON JSON-RPC with automatic reconnect, QR / 8-digit Pairing Code, and multi-file auth state.
  - `:cloud_api` mode — Pure-Ruby `Net::HTTP` client for Meta WhatsApp Business Cloud API `v21.0` with automatic `429`/`5xx` exponential backoff retries and detailed error diagnostics.
  - `:memory` mode — Deterministic in-memory adapter for unit tests and dry-run payload verification.
- **Interactive Builders**:
  - `WhatsappWebRuby::Button` & `WhatsappWebRuby::ButtonV2` (Quick Reply, URL CTA, Webview, Copy/OTP Code, Call, Single Select Sections & Rows, Flows v3, Location/Address Request, Product/Catalog, Pix/Payment Status, Order Status, Reminders).
  - `WhatsappWebRuby::Carousel` (Swipeable multi-card product & action carousels).
  - `WhatsappWebRuby::FlowBuilder` (WhatsApp Flows `3.1` JSON schema & `flow` button generator).
  - `WhatsappWebRuby::AIRich` / `WhatsappWebRuby::Rich` (Markdown inline entity extraction for hyperlinks, citations & LaTeX, code syntax tokenizer, and markdown table builder).
  - `WhatsappWebRuby::NewsletterHelper` (WhatsApp Channels `@newsletter` follow/unfollow/mute/metadata & broadcast builder).
- **Zero-Token Meta Cloud API Converter**:
  - `WhatsappWebRuby.from_cloud_api_message` & `WhatsappWebRuby.to_cloud_api_message`
  - `WhatsappWebRuby.sanitize_whatsapp_number`, `WhatsappWebRuby.generate_waveform`, `WhatsappWebRuby.serialize_message`, `WhatsappWebRuby.diagnose_meta_cloud_api_error`
- **Production Automation Engine**:
  - `WhatsappWebRuby::Automation::Router` — Declarative `!command`, regex pattern, button-reply wildcard, and middleware chain.
  - `WhatsappWebRuby::Automation::Dispatcher` — Thread-safe queue with per-JID anti-ban rate limiting, idempotency key deduplication, priority lanes, exponential backoff retries, and dead-letter hooks.
  - `WhatsappWebRuby::Automation::WebhookServer` — Pure-Ruby TCPServer REST API (`/v1/messages/send`, `/v1/messages/interactive`, `/v1/messages/cloud-api`, `/v1/session/pairing-code`, `/v1/health`) with Bearer auth and HMAC-SHA256 outgoing webhooks.

## Installation

Add to your `Gemfile`:

```ruby
gem "whatsapp-web-ruby", git: "https://github.com/KazeDevID/whatsapp-web-ruby"
```

If using Multi-Device `:bridge` mode, dependencies inside `lib/whatsapp_web_ruby/bridge` are auto-installed on first run, or can be installed manually:

```bash
cd lib/whatsapp_web_ruby/bridge && npm install --omit=dev --no-bin-links
```

## Quick Start (Multi-Device Bot + Automation Router)

```ruby
require "whatsapp-web-ruby"

sock = WhatsappWebRuby.make_wa_socket(
  mode: :bridge,
  auth_folder: "./auth_info",
  print_qr_in_terminal: true
)

router = WhatsappWebRuby::Automation::Router.new(prefix: "!")

router.on_command("menu") do |ctx|
  ctx.button_builder
     .set_title("Kaze Store")
     .set_body("Choose an automated action below:")
     .set_footer("Powered by whatsapp-web-ruby")
     .add_reply("Order Status", "btn_order_status")
     .add_otp("829104", "Copy Promo Code")
     .add_url("Documentation", "https://github.com/KazeDevID/whatsapp-web-ruby")
     .send(ctx.jid)
end

router.on_button("btn_order_*") do |ctx|
  ctx.reply("Checking order for #{ctx.sender}...")
end

router.attach(sock)
sock.connect

# Optional Pairing Code instead of QR:
# puts sock.request_pairing_code("6281234567890")
```

## Rate-Limited Automation Dispatcher

```ruby
dispatcher = WhatsappWebRuby::Automation::Dispatcher.new(
  socket: sock,
  per_jid_interval: 1.5,
  max_attempts: 3,
  on_dead_letter: ->(job, err) { warn "Failed #{job.id}: #{err.message}" }
).start

dispatcher.enqueue(
  jid: "6281234567890",
  content: { text: "Order #1024 confirmed." },
  idempotency_key: "order-1024-confirm"
)
```

## Meta Cloud API Mode (Zero Node.js)

```ruby
sock = WhatsappWebRuby.make_wa_socket(
  mode: :cloud_api,
  phone_number_id: ENV.fetch("WHATSAPP_PHONE_NUMBER_ID"),
  access_token: ENV.fetch("WHATSAPP_ACCESS_TOKEN")
).connect

sock.send_message("6281234567890", { text: "Hello from pure Ruby!" })
```

## Running Tests

```bash
rake test
```

## License

MIT License — KazeDevID.
