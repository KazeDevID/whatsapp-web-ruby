# frozen_string_literal: true

module WhatsappWebRuby
  module Utils
    # Thread-safe EventEmitter mirroring Baileys' `sock.ev` interface.
    class EventEmitter
      def initialize
        @mutex = Mutex.new
        @listeners = Hash.new { |h, k| h[k] = [] }
        @buffering = false
        @buffer_queue = []
      end

      def on(event, &block)
        raise ArgumentError, "Block is required" unless block_given?

        key = normalize_event(event)
        @mutex.synchronize do
          @listeners[key] << block
        end
        block
      end

      def once(event, &block)
        raise ArgumentError, "Block is required" unless block_given?

        wrapper = nil
        wrapper = proc do |*args|
          off(event, wrapper)
          block.call(*args)
        end
        on(event, &wrapper)
      end

      def off(event, listener = nil)
        key = normalize_event(event)
        @mutex.synchronize do
          if listener
            @listeners[key].delete(listener)
          else
            @listeners.delete(key)
          end
        end
        self
      end

      def remove_all_listeners(event = nil)
        @mutex.synchronize do
          if event
            @listeners.delete(normalize_event(event))
          else
            @listeners.clear
          end
        end
        self
      end

      def emit(event, payload = nil)
        key = normalize_event(event)
        callbacks = nil

        @mutex.synchronize do
          if @buffering
            @buffer_queue << [key, payload]
            return false
          end
          callbacks = @listeners[key].dup
        end

        callbacks.each do |cb|
          cb.call(payload)
        rescue StandardError => e
          warn "[WhatsappWebRuby::EventEmitter] listener error on #{key}: #{e.class} - #{e.message}"
        end
        !callbacks.empty?
      end

      def buffering?
        @mutex.synchronize { @buffering }
      end

      def buffer
        @mutex.synchronize { @buffering = true }
        self
      end

      def flush
        queued = @mutex.synchronize do
          return false unless @buffering

          @buffering = false
          items = @buffer_queue.dup
          @buffer_queue.clear
          items
        end

        queued.each { |key, payload| emit(key, payload) }
        true
      end

      # Baileys-style `ev.process { |events| ... }` batch handler.
      def process(&block)
        raise ArgumentError, "Block is required" unless block_given?

        registered = {}
        %i[connection_update creds_update messages_upsert messages_update
           presence_update group_participants_update groups_upsert].each do |ev_name|
          registered[ev_name] = on(ev_name) do |data|
            block.call({ ev_name => data })
          end
        end

        proc do
          registered.each { |ev_name, cb| off(ev_name, cb) }
        end
      end

      def listener_count(event)
        @mutex.synchronize { @listeners[normalize_event(event)].size }
      end

      private

      def normalize_event(event)
        event.to_s.tr(".", "_").tr("-", "_").to_sym
      end
    end
  end
end
