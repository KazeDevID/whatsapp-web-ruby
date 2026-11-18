# frozen_string_literal: true

module WhatsappWebRuby
  module Builders
    # Swipeable Multi-Card Carousel Builder mirroring `WhatsappWebRuby::Carousel`.
    class Carousel < BaseBuilder
      attr_reader :cards

      def initialize(client = nil)
        super()
        @client = client
        @cards = []
      end

      def add_card(card)
        Array(card).each do |c|
          @cards << c
        end
        self
      end

      def build(jid = nil, _options = {})
        built_cards = @cards.map do |c|
          c.respond_to?(:to_card) ? c.to_card : c
        end

        payload = @_extra_payload.merge(
          viewOnceMessage: {
            message: {
              messageContextInfo: {
                deviceListMetadata: {},
                deviceListMetadataVersion: 2
              },
              interactiveMessage: {
                header: {
                  title: @_title.empty? ? nil : @_title,
                  hasMediaAttachment: false
                }.compact,
                body: { text: @_body.empty? ? " " : @_body },
                footer: @_footer.empty? ? nil : { text: @_footer },
                contextInfo: @_context_info,
                carouselMessage: {
                  cards: built_cards,
                  messageVersion: 1
                }
              }.compact
            }
          }
        )

        jid ? { jid: Utils::Jid.to_jid(jid), message: payload } : payload
      end

      def send(jid, options = {})
        raise ConfigurationError, "Socket client is required to send message" unless @client
        raise ValidationError, "Carousel requires at least one card" if @cards.empty?

        @client.send_message(jid, build(nil, options), options)
      end
    end
  end
end
