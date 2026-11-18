# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"

module BaileysRec
  module Transport
    # Resilient JSON-RPC NDJSON Bridge to the `baileys-rec` Multi-Device engine.
    # Manages process lifecycle, correlated RPC calls, timeouts, and event streaming.
    class BridgeAdapter
      DEFAULT_WORKER_PATH = File.expand_path("../bridge/worker.mjs", __dir__)

      def initialize(auth_folder: "./auth_info", node_bin: "node", worker_path: DEFAULT_WORKER_PATH,
                     timeout: 30, auto_restart: true, print_qr_in_terminal: false, browser: nil)
        @auth_folder = auth_folder.to_s
        @node_bin = node_bin.to_s
        @worker_path = worker_path.to_s
        @timeout = timeout
        @auto_restart = auto_restart
        @print_qr_in_terminal = print_qr_in_terminal
        @browser = browser || ["BaileysRecRuby", "Chrome", "1.6.0"]

        @mutex = Mutex.new
        @write_mutex = Mutex.new
        @pending = {}
        @emitter = nil
        @stdin = nil
        @wait_thread = nil
        @reader_thread = nil
        @running = false
        @connected = false
      end

      def connect(emitter)
        @emitter = emitter
        spawn_worker!
        rpc("init", {
          authFolder: @auth_folder,
          printQRInTerminal: @print_qr_in_terminal,
          browser: @browser
        })
      end

      def disconnect
        @auto_restart = false
        @running = false
        @connected = false
        begin
          rpc("shutdown", {}) if @stdin && !@stdin.closed?
        rescue StandardError
          nil
        end
        cleanup_streams
      end

      def connected?
        @running && @connected
      end

      def send_message(jid, content, options = {})
        rpc("sendMessage", { jid: jid, content: content, options: options })
      end

      def send_interactive(jid, content, options = {})
        rpc("sendInteractive", { jid: jid, content: content, options: options })
      end

      def request_pairing_code(phone_number, custom_code = nil)
        rpc("requestPairingCode", { phoneNumber: phone_number, customCode: custom_code })
      end

      def send_presence_update(type, jid)
        rpc("sendPresenceUpdate", { type: type, jid: jid })
      end

      def on_whatsapp(*phone_numbers)
        rpc("onWhatsApp", { phoneNumbers: phone_numbers.flatten })
      end

      def group_create(subject, participants)
        rpc("groupCreate", { subject: subject, participants: participants })
      end

      def group_metadata(jid)
        rpc("groupMetadata", { jid: jid })
      end

      def group_participants_update(jid, participants, action)
        rpc("groupParticipantsUpdate", { jid: jid, participants: participants, action: action })
      end

      def newsletter_follow(jid)
        rpc("newsletterFollow", { jid: jid })
      end

      def newsletter_unfollow(jid)
        rpc("newsletterUnfollow", { jid: jid })
      end

      def newsletter_mute(jid)
        rpc("newsletterMute", { jid: jid })
      end

      def newsletter_unmute(jid)
        rpc("newsletterUnmute", { jid: jid })
      end

      def newsletter_metadata(jid)
        rpc("newsletterMetadata", { jid: jid })
      end

      def query(node)
        rpc("query", { node: node })
      end

      def logout
        rpc("logout", {})
      end

      def rpc(method, params = {})
        raise ConnectionError, "Bridge worker is not running" unless @running && @stdin && !@stdin.closed?

        id = SecureRandom.uuid
        queue = Queue.new

        @mutex.synchronize { @pending[id] = queue }

        frame = JSON.generate({ id: id, method: method, params: params })
        @write_mutex.synchronize do
          @stdin.puts(frame)
          @stdin.flush
        end

        response = pop_with_timeout(queue, @timeout)
        if response.nil?
          @mutex.synchronize { @pending.delete(id) }
          raise TimeoutError, "Bridge RPC '#{method}' timed out after #{@timeout}s"
        end

        if response["error"]
          raise TransportError.new(
            response["error"]["message"] || "Bridge RPC error",
            code: response["error"]["code"]
          )
        end

        response["result"]
      end

      private

      def spawn_worker!
        raise ConfigurationError, "Bridge worker script missing: #{@worker_path}" unless File.exist?(@worker_path)

        ensure_bridge_dependencies!
        stdin, stdout, stderr, wait_thr = Open3.popen3(@node_bin, @worker_path)
        @stdin = stdin
        @stdout = stdout
        @stderr = stderr
        @wait_thread = wait_thr
        @running = true

        @reader_thread = Thread.new { read_stdout_loop(stdout) }
        @stderr_thread = Thread.new { read_stderr_loop(stderr) }
      end

      def ensure_bridge_dependencies!
        bridge_dir = File.dirname(@worker_path)
        pkg_json = File.join(bridge_dir, "package.json")
        baileys_dir = File.join(bridge_dir, "node_modules", "baileys-rec")
        return unless File.exist?(pkg_json) && !File.directory?(baileys_dir)

        warn "[BaileysRec::Bridge] Installing Node.js bridge dependencies in #{bridge_dir}..."
        ok = system("npm", "install", "--omit=dev", "--no-bin-links", "--no-audit", "--no-fund", chdir: bridge_dir)
        return if ok

        raise ConfigurationError,
              "Failed installing bridge dependencies in #{bridge_dir}. Run manually: cd #{bridge_dir} && npm install --omit=dev --no-bin-links"
      end

      def read_stdout_loop(stdout)
        while @running && (line = stdout.gets)
          line = line.strip
          next if line.empty?

          msg = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          next unless msg.is_a?(Hash)

          if msg["id"]
            queue = @mutex.synchronize { @pending.delete(msg["id"]) }
            queue&.push(msg)
          elsif msg["event"]
            handle_worker_event(msg["event"], msg["data"])
          end
        end
      ensure
        handle_worker_exit
      end

      def read_stderr_loop(stderr)
        while @running && (line = stderr.gets)
          @emitter&.emit(:bridge_log, { level: "stderr", message: line.chomp })
        end
      end

      def handle_worker_event(event_name, data)
        sym = event_name.to_s.tr(".", "_").to_sym
        if sym == :connection_update && data.is_a?(Hash)
          @connected = (data["connection"] == "open")
        end
        @emitter&.emit(sym, data)
      end

      def handle_worker_exit
        @running = false
        @connected = false
        @mutex.synchronize do
          @pending.each_value { |q| q.push({ "error" => { "message" => "Bridge worker exited" } }) }
          @pending.clear
        end

        return unless @auto_restart && @emitter

        @emitter.emit(:connection_update, { "connection" => "close", "restarting" => true })
        sleep 2
        spawn_worker!
      rescue StandardError => e
        @emitter&.emit(:connection_update, { "connection" => "close", "error" => e.message })
      end

      def cleanup_streams
        [@stdin, @stdout, @stderr].each do |io|
          io&.close unless io&.closed?
        rescue StandardError
          nil
        end
      end

      def pop_with_timeout(queue, timeout_sec)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
        loop do
          begin
            return queue.pop(true)
          rescue ThreadError
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return nil if remaining <= 0

            sleep([remaining, 0.02].min)
          end
        end
      end
    end
  end
end
