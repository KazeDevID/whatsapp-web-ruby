# frozen_string_literal: true

require_relative "lib/whatsapp_web_ruby/version"

Gem::Specification.new do |spec|
  spec.name = "whatsapp-web-ruby"
  spec.version = WhatsappWebRuby::VERSION
  spec.authors = ["KazeDevID"]
  spec.email = ["mkzstyle31@gmail.com"]

  spec.summary = "WhatsApp Bot & Automation Library for Ruby (Multi-Device, Interactive Buttons, Carousels, Flows v3.1, AI Rich & Meta Cloud API)."
  spec.description = <<~DESC
    whatsapp-web-ruby brings the full WhatsApp Multi-Device and interactive message suite
    to Ruby: Button & Carousel builders, WhatsApp Flows v3.1, AI Rich messages,
    Newsletter/Channels helper, zero-token Meta Cloud API payload conversion,
    resilient multi-device bridge transport, and an enterprise message automation
    router, rate-limited dispatcher, and REST webhook server.
  DESC
  spec.homepage = "https://github.com/KazeDevID/whatsapp-web-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.glob("{bin,lib,examples}/**/*") + %w[LICENSE README.md Rakefile Gemfile]
  spec.bindir = "bin"
  spec.executables = ["whatsapp-web-ruby"]
  spec.require_paths = ["lib"]
end
