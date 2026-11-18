# frozen_string_literal: true

require "json"
require "fileutils"

module BaileysRec
  module Auth
    # Multi-file auth state store mirroring Baileys `useMultiFileAuthState`.
    class MultiFileAuthState
      attr_reader :folder, :creds

      def initialize(folder = "./auth_info")
        @folder = File.expand_path(folder)
        @mutex = Mutex.new
        FileUtils.mkdir_p(@folder)
        @creds = read_json("creds.json") || {}
      end

      def state
        { creds: @creds, folder: @folder }
      end

      def save_creds(new_creds = nil)
        @mutex.synchronize do
          @creds = new_creds if new_creds
          write_json("creds.json", @creds)
        end
      end

      def get_keys(type, ids)
        @mutex.synchronize do
          result = {}
          Array(ids).each do |id|
            filename = sanitize_filename("#{type}-#{id}.json")
            val = read_json(filename)
            result[id] = val if val
          end
          result
        end
      end

      def set_keys(data)
        @mutex.synchronize do
          data.each do |category, entries|
            next unless entries.is_a?(Hash)

            entries.each do |id, value|
              filename = sanitize_filename("#{category}-#{id}.json")
              if value.nil?
                path = File.join(@folder, filename)
                File.delete(path) if File.exist?(path)
              else
                write_json(filename, value)
              end
            end
          end
        end
      end

      def clear!
        @mutex.synchronize do
          FileUtils.rm_rf(@folder)
          FileUtils.mkdir_p(@folder)
          @creds = {}
        end
      end

      private

      def sanitize_filename(name)
        name.to_s.gsub("/", "__").gsub(":", "-")
      end

      def read_json(filename)
        path = File.join(@folder, filename)
        return nil unless File.exist?(path)

        JSON.parse(File.read(path, encoding: "UTF-8"))
      rescue JSON::ParserError
        nil
      end

      def write_json(filename, obj)
        path = File.join(@folder, filename)
        tmp = "#{path}.tmp.#{Process.pid}"
        File.write(tmp, JSON.pretty_generate(obj), encoding: "UTF-8")
        File.rename(tmp, path)
      end
    end

    # Single-file JSON auth state store.
    class SingleFileAuthState
      attr_reader :file_path, :creds

      def initialize(file_path = "./auth_info.json")
        @file_path = File.expand_path(file_path)
        @mutex = Mutex.new
        FileUtils.mkdir_p(File.dirname(@file_path))
        data = load_all
        @creds = data["creds"] || {}
        @keys = data["keys"] || {}
      end

      def state
        { creds: @creds, file_path: @file_path }
      end

      def save_creds(new_creds = nil)
        @mutex.synchronize do
          @creds = new_creds if new_creds
          persist_all
        end
      end

      def get_keys(type, ids)
        @mutex.synchronize do
          bucket = @keys[type.to_s] || {}
          Array(ids).each_with_object({}) do |id, acc|
            acc[id] = bucket[id.to_s] if bucket.key?(id.to_s)
          end
        end
      end

      def set_keys(data)
        @mutex.synchronize do
          data.each do |category, entries|
            next unless entries.is_a?(Hash)

            cat = (@keys[category.to_s] ||= {})
            entries.each do |id, value|
              if value.nil?
                cat.delete(id.to_s)
              else
                cat[id.to_s] = value
              end
            end
          end
          persist_all
        end
      end

      private

      def load_all
        return {} unless File.exist?(@file_path)

        JSON.parse(File.read(@file_path, encoding: "UTF-8"))
      rescue JSON::ParserError
        {}
      end

      def persist_all
        tmp = "#{@file_path}.tmp.#{Process.pid}"
        File.write(tmp, JSON.pretty_generate({ creds: @creds, keys: @keys }), encoding: "UTF-8")
        File.rename(tmp, @file_path)
      end
    end
  end
end
