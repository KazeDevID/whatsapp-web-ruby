# frozen_string_literal: true

module BaileysRec
  module Automation
    # Context object passed into automation route handlers.
    class Context
      attr_reader :socket, :message, :params

      def initialize(socket:, message:, params: {})
        @socket = socket
        @message = message
        @params = params
      end

      def jid
        @message[:from]
      end

      def sender
        @message[:sender]
      end

      def body
        @message[:body].to_s
      end

      def button_id
        @message.dig(:interactive, :id)
      end

      def reply(content, options = {})
        payload = content.is_a?(String) ? { text: content } : content
        @socket.send_message(jid, payload, options)
      end

      def button_builder
        Builders::Button.new(@socket)
      end

      def carousel_builder
        Builders::Carousel.new(@socket)
      end
    end

    # Declarative Bot Command, Pattern, Button-ID, and Middleware Router.
    class Router
      def initialize(prefix: "!")
        @prefix = prefix.to_s
        @middlewares = []
        @routes = []
        @fallback = nil
      end

      def use(&block)
        raise ArgumentError, "Middleware block required" unless block_given?

        @middlewares << block
        self
      end

      def on_command(name, &block)
        cmd = name.to_s.downcase
        @routes << {
          type: :command,
          matcher: ->(msg) { match_command?(msg[:body].to_s, cmd) },
          handler: block
        }
        self
      end

      def on_pattern(regex, &block)
        @routes << {
          type: :pattern,
          matcher: ->(msg) { msg[:body].to_s.match(regex) },
          handler: block
        }
        self
      end

      def on_button(id_pattern, &block)
        @routes << {
          type: :button,
          matcher: lambda do |msg|
            btn_id = msg.dig(:interactive, :id).to_s
            return false if btn_id.empty?

            id_pattern.is_a?(Regexp) ? btn_id.match?(id_pattern) : File.fnmatch?(id_pattern.to_s, btn_id)
          end,
          handler: block
        }
        self
      end

      def on_any(&block)
        @fallback = block
        self
      end

      def attach(socket)
        socket.ev.on(:messages_upsert) do |upsert|
          messages = upsert.is_a?(Hash) ? (upsert["messages"] || upsert[:messages] || []) : Array(upsert)
          messages.each do |raw|
            serialized = Utils::CloudApi.serialize_message(raw)
            next unless serialized
            next if serialized[:from_me]

            dispatch(socket, serialized)
          end
        end
        self
      end

      def dispatch(socket, serialized_message)
        ctx = Context.new(socket: socket, message: serialized_message)

        matched_route = nil
        match_data = nil
        @routes.each do |route|
          res = route[:matcher].call(serialized_message)
          if res
            matched_route = route
            match_data = res
            break
          end
        end

        terminal = if matched_route
                     -> { matched_route[:handler].call(ctx, match_data) }
                   elsif @fallback
                     -> { @fallback.call(ctx) }
                   else
                     -> { nil }
                   end

        chain = @middlewares.reverse.reduce(terminal) do |next_fn, mw|
          -> { mw.call(ctx, next_fn) }
        end

        chain.call
      end

      private

      def match_command?(body, cmd)
        trimmed = body.strip
        return nil unless trimmed.start_with?(@prefix)

        parts = trimmed[@prefix.length..].split(/\s+/, 2)
        return nil unless parts.first&.downcase == cmd

        { command: cmd, args: parts[1].to_s.strip }
      end
    end
  end
end
