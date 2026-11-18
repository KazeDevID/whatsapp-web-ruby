# frozen_string_literal: true

module WhatsappWebRuby
  # Core WhatsApp Multi-Device / Cloud API Socket mirroring `makeWASocket`.
  class Socket
    attr_reader :ev, :adapter, :mode, :config

    def initialize(config = {})
      @config = config.dup
      @mode = (@config[:mode] || detect_mode(@config)).to_sym
      @ev = Utils::EventEmitter.new
      @adapter = @config[:adapter] || build_adapter(@mode, @config)
      @max_retries = @config.fetch(:max_retries, 3).to_i
      @retry_base_delay = @config.fetch(:retry_base_delay, 0.5).to_f
      @sent_ids_mutex = Mutex.new
      @sent_ids = []
    end

    def sent_by_me?(msg_id)
      return false if msg_id.nil? || msg_id.to_s.empty?

      @sent_ids_mutex.synchronize { @sent_ids.include?(msg_id.to_s) }
    end

    def connect
      @adapter.connect(@ev)
      self
    end

    def connected?
      @adapter.connected?
    end

    def send_message(jid, content, options = {})
      target_jid = Utils::Jid.to_jid(jid)
      payload = normalize_outgoing_content(content)

      res = with_retry do
        @adapter.send_message(target_jid, payload, options)
      end
      record_sent_id(res)
      res
    end

    def send_interactive(jid, content, options = {})
      target_jid = Utils::Jid.to_jid(jid)
      res = if @adapter.respond_to?(:send_interactive)
              with_retry { @adapter.send_interactive(target_jid, content, options) }
            else
              send_message(target_jid, content, options)
            end
      record_sent_id(res)
      res
    end

    def send_cloud_api(jid, cloud_api_payload, options = {})
      target_jid = Utils::Jid.to_jid(jid)
      res = if @mode == :cloud_api
              with_retry { @adapter.send_message(target_jid, cloud_api_payload, options) }
            else
              converted = Utils::CloudApi.from_cloud_api_message(cloud_api_payload)
              send_message(target_jid, converted, options)
            end
      record_sent_id(res)
      res
    end

    def request_pairing_code(phone_number, custom_code = nil)
      clean = Utils::Jid.sanitize_whatsapp_number(phone_number)
      raise ValidationError, "Valid phone number is required for pairing code" if clean.empty?
      unless @adapter.respond_to?(:request_pairing_code)
        raise ConfigurationError, "Pairing code is only supported in :bridge or :memory mode"
      end

      @adapter.request_pairing_code(clean, custom_code)
    end

    def send_presence_update(type, jid)
      return false unless @adapter.respond_to?(:send_presence_update)

      @adapter.send_presence_update(type.to_s, Utils::Jid.to_jid(jid))
    end

    def on_whatsapp(*phone_numbers)
      raise ConfigurationError, "on_whatsapp requires :bridge or :memory mode" unless @adapter.respond_to?(:on_whatsapp)

      @adapter.on_whatsapp(*phone_numbers)
    end

    def group_create(subject, participants = [])
      jids = Array(participants).map { |p| Utils::Jid.to_jid(p) }
      @adapter.group_create(subject.to_s, jids)
    end

    def group_metadata(jid)
      @adapter.group_metadata(Utils::Jid.to_jid(jid))
    end

    def group_participants_update(jid, participants, action)
      jids = Array(participants).map { |p| Utils::Jid.to_jid(p) }
      @adapter.group_participants_update(Utils::Jid.to_jid(jid), jids, action.to_s)
    end

    def newsletter_follow(jid) = @adapter.newsletter_follow(jid.to_s)
    def newsletter_unfollow(jid) = @adapter.newsletter_unfollow(jid.to_s)
    def newsletter_mute(jid) = @adapter.newsletter_mute(jid.to_s)
    def newsletter_unmute(jid) = @adapter.newsletter_unmute(jid.to_s)
    def newsletter_metadata(jid) = @adapter.newsletter_metadata(jid.to_s)

    def query(node)
      raise ConfigurationError, "Direct IQ query not supported by #{@mode} adapter" unless @adapter.respond_to?(:query)

      @adapter.query(node)
    end

    def logout
      @adapter.logout if @adapter.respond_to?(:logout)
    end

    def end_connection(_reason = nil)
      @adapter.disconnect
    end

    private

    def detect_mode(cfg)
      return :cloud_api if cfg[:phone_number_id] && cfg[:access_token]

      :bridge
    end

    def build_adapter(mode, cfg)
      case mode
      when :bridge
        Transport::BridgeAdapter.new(
          auth_folder: cfg[:auth_folder] || cfg.dig(:auth, :folder) || "./auth_info",
          node_bin: cfg[:node_bin] || "node",
          worker_path: cfg[:worker_path] || Transport::BridgeAdapter::DEFAULT_WORKER_PATH,
          timeout: cfg.fetch(:timeout, 30),
          auto_restart: cfg.fetch(:auto_restart, true),
          print_qr_in_terminal: cfg.fetch(:print_qr_in_terminal, false),
          browser: cfg[:browser]
        )
      when :cloud_api
        Transport::MetaCloudAdapter.new(
          phone_number_id: cfg[:phone_number_id],
          access_token: cfg[:access_token],
          api_version: cfg.fetch(:api_version, "v21.0"),
          max_retries: cfg.fetch(:max_retries, 3),
          timeout: cfg.fetch(:timeout, 15)
        )
      when :memory
        Transport::MemoryAdapter.new
      else
        raise ConfigurationError, "Unknown socket mode: #{mode}"
      end
    end

    def normalize_outgoing_content(content)
      if content.respond_to?(:build) && !content.is_a?(Hash)
        return content.build
      end
      if content.is_a?(Hash) && content[:messaging_product] == "whatsapp" && @mode != :cloud_api
        return Utils::CloudApi.from_cloud_api_message(content)
      end

      content
    end

    def with_retry
      attempt = 0
      loop do
        attempt += 1
        return yield
      rescue RateLimitError, TimeoutError, ConnectionError => e
        raise e if attempt > @max_retries

        delay = (e.respond_to?(:retry_after) && e.retry_after) ? e.retry_after : (@retry_base_delay * (2**(attempt - 1)))
        sleep(delay)
      end
    end

    def record_sent_id(res)
      return unless res.is_a?(Hash)

      msg_id = res.dig("key", "id") || res.dig(:key, :id) || res["id"] || res[:id]
      return if msg_id.nil? || msg_id.to_s.empty?

      @sent_ids_mutex.synchronize do
        @sent_ids << msg_id.to_s
        @sent_ids.shift while @sent_ids.size > 300
      end
    end
  end
end
