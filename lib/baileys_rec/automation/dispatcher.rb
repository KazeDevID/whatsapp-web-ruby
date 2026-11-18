# frozen_string_literal: true

require "securerandom"

module BaileysRec
  module Automation
    # Thread-safe Message Automation Queue & Rate-Limited Dispatcher.
    # Provides anti-ban per-recipient spacing, idempotency deduplication,
    # exponential backoff retries, and dead-letter hooks.
    class Dispatcher
      Job = Struct.new(
        :id, :jid, :content, :options, :idempotency_key,
        :attempts, :max_attempts, :status, :result, :error, :created_at,
        keyword_init: true
      )

      attr_reader :stats

      def initialize(socket:, per_jid_interval: 1.0, max_attempts: 3, base_backoff: 0.5, on_dead_letter: nil)
        @socket = socket
        @per_jid_interval = per_jid_interval.to_f
        @max_attempts = max_attempts.to_i
        @base_backoff = base_backoff.to_f
        @on_dead_letter = on_dead_letter

        @mutex = Mutex.new
        @cond = ConditionVariable.new
        @queue = []
        @jobs = {}
        @idempotency_index = {}
        @last_sent_at = {}
        @running = false
        @worker_thread = nil
        @stats = { enqueued: 0, sent: 0, retried: 0, failed: 0, deduplicated: 0 }
      end

      def start
        @mutex.synchronize do
          return self if @running

          @running = true
          @worker_thread = Thread.new { process_loop }
        end
        self
      end

      def stop(drain: true)
        wait_until_empty if drain
        @mutex.synchronize do
          @running = false
          @cond.broadcast
        end
        @worker_thread&.join(5)
        self
      end

      def enqueue(jid:, content:, options: {}, idempotency_key: nil, priority: :normal)
        target_jid = Utils::Jid.to_jid(jid)

        @mutex.synchronize do
          if idempotency_key && @idempotency_index.key?(idempotency_key)
            @stats[:deduplicated] += 1
            return @jobs[@idempotency_index[idempotency_key]]
          end

          job = Job.new(
            id: SecureRandom.uuid,
            jid: target_jid,
            content: content,
            options: options,
            idempotency_key: idempotency_key,
            attempts: 0,
            max_attempts: @max_attempts,
            status: :queued,
            created_at: Time.now.to_i
          )

          @jobs[job.id] = job
          @idempotency_index[idempotency_key] = job.id if idempotency_key
          @stats[:enqueued] += 1

          if priority == :high
            @queue.unshift(job)
          else
            @queue.push(job)
          end
          @cond.signal
          job
        end
      end

      def find_job(id)
        @mutex.synchronize { @jobs[id] }
      end

      def pending_count
        @mutex.synchronize { @queue.size }
      end

      def wait_until_empty(timeout: 10)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          empty = @mutex.synchronize do
            @queue.empty? && @jobs.values.none? { |j| j.status == :processing }
          end
          return true if empty
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.02
        end
      end

      private

      def process_loop
        loop do
          job = @mutex.synchronize do
            while @running && @queue.empty?
              @cond.wait(@mutex)
            end
            break nil unless @running

            j = @queue.shift
            j.status = :processing if j
            j
          end
          break unless job

          execute_job(job)
        end
      end

      def execute_job(job)
        enforce_rate_limit(job.jid)
        job.attempts += 1
        result = @socket.send_message(job.jid, job.content, job.options)

        @mutex.synchronize do
          @last_sent_at[job.jid] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          job.status = :sent
          job.result = result
          @stats[:sent] += 1
        end
      rescue StandardError => e
        if job.attempts < job.max_attempts
          @mutex.synchronize { @stats[:retried] += 1 }
          sleep(@base_backoff * (2**(job.attempts - 1)))
          @mutex.synchronize do
            job.status = :queued
            @queue.push(job)
            @cond.signal
          end
        else
          @mutex.synchronize do
            job.status = :failed
            job.error = "#{e.class}: #{e.message}"
            @stats[:failed] += 1
          end
          @on_dead_letter&.call(job, e)
        end
      end

      def enforce_rate_limit(jid)
        return if @per_jid_interval <= 0

        wait_needed = @mutex.synchronize do
          last = @last_sent_at[jid]
          if last
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - last
            @per_jid_interval - elapsed
          else
            0.0
          end
        end
        sleep(wait_needed) if wait_needed.positive?
      end
    end
  end
end
