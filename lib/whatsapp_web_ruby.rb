# frozen_string_literal: true

require_relative "whatsapp_web_ruby/version"
require_relative "whatsapp_web_ruby/errors"
require_relative "whatsapp_web_ruby/utils/event_emitter"
require_relative "whatsapp_web_ruby/utils/jid"
require_relative "whatsapp_web_ruby/utils/cloud_api"
require_relative "whatsapp_web_ruby/utils/newsletter_helper"
require_relative "whatsapp_web_ruby/auth/multi_file_auth_state"
require_relative "whatsapp_web_ruby/builders/base_builder"
require_relative "whatsapp_web_ruby/builders/button"
require_relative "whatsapp_web_ruby/builders/carousel"
require_relative "whatsapp_web_ruby/builders/flow_builder"
require_relative "whatsapp_web_ruby/builders/ai_rich"
require_relative "whatsapp_web_ruby/transport/meta_cloud_adapter"
require_relative "whatsapp_web_ruby/transport/bridge_adapter"
require_relative "whatsapp_web_ruby/transport/memory_adapter"
require_relative "whatsapp_web_ruby/socket"
require_relative "whatsapp_web_ruby/automation/router"
require_relative "whatsapp_web_ruby/automation/dispatcher"
require_relative "whatsapp_web_ruby/automation/webhook_server"

module WhatsappWebRuby
  Button = Builders::Button
  ButtonV2 = Builders::ButtonV2
  Carousel = Builders::Carousel
  FlowBuilder = Builders::FlowBuilder
  AIRich = Builders::AIRich
  Rich = Builders::AIRich
  NewsletterHelper = Utils::NewsletterHelper

  class << self
    def make_wa_socket(config = {})
      Socket.new(config)
    end
    alias makeWASocket make_wa_socket

    def use_multi_file_auth_state(folder = "./auth_info")
      Auth::MultiFileAuthState.new(folder)
    end
    alias useMultiFileAuthState use_multi_file_auth_state

    def use_single_file_auth_state(file_path = "./auth_info.json")
      Auth::SingleFileAuthState.new(file_path)
    end
    alias useSingleFileAuthState use_single_file_auth_state

    def from_cloud_api_message(payload)
      Utils::CloudApi.from_cloud_api_message(payload)
    end
    alias fromCloudApiMessage from_cloud_api_message

    def to_cloud_api_message(content, recipient_phone = "")
      Utils::CloudApi.to_cloud_api_message(content, recipient_phone)
    end
    alias toCloudApiMessage to_cloud_api_message

    def sanitize_whatsapp_number(phone, default_country_code: "62")
      Utils::Jid.sanitize_whatsapp_number(phone, default_country_code: default_country_code)
    end
    alias sanitizeWhatsAppNumber sanitize_whatsapp_number

    def diagnose_meta_cloud_api_error(error)
      Utils::CloudApi.diagnose_meta_cloud_api_error(error)
    end

    def generate_waveform(samples = 64, **options)
      Utils::CloudApi.generate_waveform(samples, **options)
    end

    def serialize_message(msg)
      Utils::CloudApi.serialize_message(msg)
    end
  end
end

# Backward-compatible constant alias
BaileysRec = WhatsappWebRuby unless defined?(BaileysRec)
