# frozen_string_literal: true

require "securerandom"

module BaileysRec
  module Transport
    # In-memory test and dry-run adapter for offline automation verification.
    class MemoryAdapter
      attr_reader :sent_messages, :presence_updates, :queries

      def initialize
        @sent_messages = []
        @presence_updates = []
        @queries = []
        @connected = false
        @emitter = nil
      end

      def connect(emitter)
        @emitter = emitter
        @connected = true
        emitter.emit(:connection_update, { "connection" => "open", "mode" => "memory" })
        { "status" => "open", "mode" => "memory" }
      end

      def disconnect
        @connected = false
        @emitter&.emit(:connection_update, { "connection" => "close" })
      end

      def connected?
        @connected
      end

      def send_message(jid, content, options = {})
        record = {
          id: "MSG_#{SecureRandom.hex(8).upcase}",
          jid: jid,
          content: content,
          options: options,
          timestamp: Time.now.to_i
        }
        @sent_messages << record
        { "key" => { "remoteJid" => jid, "id" => record[:id], "fromMe" => true }, "status" => "sent" }
      end

      def send_interactive(jid, content, options = {})
        send_message(jid, { interactive: content }, options)
      end

      def request_pairing_code(phone_number, custom_code = nil)
        code = custom_code || format("%04d-%04d", rand(1000..9999), rand(1000..9999))
        { "phoneNumber" => Utils::Jid.sanitize_whatsapp_number(phone_number), "code" => code }
      end

      def send_presence_update(type, jid)
        @presence_updates << { type: type, jid: jid, timestamp: Time.now.to_i }
        true
      end

      def on_whatsapp(*phone_numbers)
        phone_numbers.flatten.map do |p|
          digits = Utils::Jid.sanitize_whatsapp_number(p)
          { "exists" => !digits.empty?, "jid" => "#{digits}@s.whatsapp.net" }
        end
      end

      def group_create(subject, participants)
        { "id" => "#{rand(10**11..10**12)}@g.us", "subject" => subject, "participants" => participants }
      end

      def group_metadata(jid)
        { "id" => jid, "subject" => "Mock Group", "participants" => [] }
      end

      def group_participants_update(jid, participants, action)
        participants.map { |p| { "jid" => p, "action" => action, "group" => jid, "status" => "200" } }
      end

      def newsletter_follow(jid) = { "status" => "followed", "jid" => jid }
      def newsletter_unfollow(jid) = { "status" => "unfollowed", "jid" => jid }
      def newsletter_mute(jid) = { "status" => "muted", "jid" => jid }
      def newsletter_unmute(jid) = { "status" => "unmuted", "jid" => jid }
      def newsletter_metadata(jid) = { "id" => jid, "name" => "Channel" }

      def query(node)
        @queries << node
        { "status" => "ok", "node" => node }
      end

      def logout
        disconnect
        true
      end
    end
  end
end
