# frozen_string_literal: true

module BaileysRec
  module Utils
    # Helper for WhatsApp Newsletter / Channels (@newsletter) operations.
    class NewsletterHelper
      class << self
        def newsletter_jid?(jid)
          Jid.newsletter_jid?(jid)
        end

        def build_newsletter_message(text, options = {})
          ctx = {
            isForwarded: options.fetch(:is_forwarded, options.fetch(:isForwarded, false)),
            forwardingScore: options.fetch(:forwarding_score, options.fetch(:forwardingScore, 0))
          }
          if options[:context_info].is_a?(Hash)
            ctx.merge!(options[:context_info])
          elsif options[:contextInfo].is_a?(Hash)
            ctx.merge!(options[:contextInfo])
          end

          payload = { text: text.to_s, contextInfo: ctx }
          extra = options.reject { |k, _| %i[is_forwarded isForwarded forwarding_score forwardingScore context_info contextInfo].include?(k) }
          payload.merge(extra)
        end

        def follow(sock, newsletter_jid)
          if sock.respond_to?(:newsletter_follow)
            sock.newsletter_follow(newsletter_jid)
          else
            sock.query(newsletter_iq(newsletter_jid, "set", "follow"))
          end
        end

        def unfollow(sock, newsletter_jid)
          if sock.respond_to?(:newsletter_unfollow)
            sock.newsletter_unfollow(newsletter_jid)
          else
            sock.query(newsletter_iq(newsletter_jid, "set", "unfollow"))
          end
        end

        def mute(sock, newsletter_jid)
          if sock.respond_to?(:newsletter_mute)
            sock.newsletter_mute(newsletter_jid)
          else
            sock.query(newsletter_iq(newsletter_jid, "set", "mute"))
          end
        end

        def unmute(sock, newsletter_jid)
          if sock.respond_to?(:newsletter_unmute)
            sock.newsletter_unmute(newsletter_jid)
          else
            sock.query(newsletter_iq(newsletter_jid, "set", "unmute"))
          end
        end

        def get_metadata(sock, newsletter_jid)
          if sock.respond_to?(:newsletter_metadata)
            sock.newsletter_metadata(newsletter_jid)
          else
            sock.query(newsletter_iq(newsletter_jid, "get", "metadata"))
          end
        end

        private

        def newsletter_iq(jid, type, action)
          {
            tag: "iq",
            attrs: { to: jid, type: type, xmlns: "newsletter" },
            content: [{ tag: action, attrs: {} }]
          }
        end
      end
    end
  end
end
