# frozen_string_literal: true

module WhatsappWebRuby
  module Utils
    module Jid
      S_WHATSAPP_NET = "s.whatsapp.net"
      G_US = "g.us"
      NEWSLETTER = "newsletter"
      LID = "lid"
      STATUS_BROADCAST = "status@broadcast"

      module_function

      # Normalizes phone numbers (e.g. "+62 812-3456-7890", "081234567890", "62812@s.whatsapp.net")
      # into digits-only E.164 format without "+".
      def sanitize_whatsapp_number(phone, default_country_code: "62")
        return "" if phone.nil?

        clean = phone.to_s.sub(/@.*$/, "").gsub(/[^0-9]/, "")
        if clean.start_with?("0") && clean.length >= 10
          clean = "#{default_country_code}#{clean[1..]}"
        end
        clean
      end

      # Converts a raw phone number or JID into a valid WhatsApp JID.
      def to_jid(input, server: S_WHATSAPP_NET)
        str = input.to_s.strip
        return str if str.include?("@")

        digits = sanitize_whatsapp_number(str)
        raise ValidationError, "Invalid WhatsApp phone/JID: #{input.inspect}" if digits.empty?

        "#{digits}@#{server}"
      end

      # Strips device suffix (`62812:12@s.whatsapp.net` -> `62812@s.whatsapp.net`).
      def jid_normalized_user(jid)
        return "" if jid.nil?

        str = jid.to_s
        return str unless str.include?("@")

        user, domain = str.split("@", 2)
        base_user = user.split(":", 2).first
        domain = S_WHATSAPP_NET if domain == "c.us"
        "#{base_user}@#{domain}"
      end

      def jid_decode(jid)
        return nil if jid.nil? || !jid.to_s.include?("@")

        user_part, server = jid.to_s.split("@", 2)
        user, device = user_part.split(":", 2)
        {
          user: user,
          device: device&.to_i,
          server: server
        }
      end

      def group_jid?(jid)
        jid.to_s.end_with?("@#{G_US}")
      end

      def newsletter_jid?(jid)
        jid.to_s.end_with?("@#{NEWSLETTER}")
      end

      def lid_jid?(jid)
        jid.to_s.end_with?("@#{LID}")
      end

      def status_broadcast?(jid)
        jid.to_s == STATUS_BROADCAST
      end
    end
  end
end
