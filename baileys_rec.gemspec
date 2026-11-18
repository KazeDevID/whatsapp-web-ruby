# frozen_string_literal: true

require_relative "lib/baileys_rec/version"

Gem::Specification.new do |spec|
  spec.name = "baileys_rec"
  spec.version = BaileysRec::VERSION
  spec.authors = ["KazeDevID"]
  spec.email = ["mkzstyle31@gmail.com"]

  spec.summary = "Ruby WhatsApp Bot & Automation SDK with Meta Cloud API parity, Interactive Builders, Flow v3, and Multi-Device Bridge."
  spec.description = <<~DESC
    BaileysRec for Ruby brings the full interactive message suite of KazeDevID/baileys-rec
    to Ruby: Button & Carousel builders, WhatsApp Flows v3.1, AI Rich messages,
    Newsletter/Channels helper, zero-token Meta Cloud API payload conversion,
    resilient multi-device bridge transport, and an enterprise message automation
    router, rate-limited dispatcher, and REST webhook server.
  DESC
  spec.homepage = "https://github.com/KazeDevID/baileys-rec-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.glob("{bin,lib,examples}/**/*") + %w[LICENSE README.md Rakefile Gemfile]
  spec.bindir = "bin"
  spec.executables = ["baileys-rec"]
  spec.require_paths = ["lib"]
end
