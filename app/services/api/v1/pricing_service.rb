require 'timeout'

module Api::V1
  class PricingService < BaseService
    def initialize(period:, hotel:, room:)
      @period = period
      @hotel = hotel
      @room = room
    end

    def run
      cache_key = "rate:#{@hotel}:#{@room}:#{@period}"
      was_cached = true

      @result = Rails.cache.fetch(cache_key, expires_in: 5.minutes, skip_nil: true) do
        was_cached = false
        send_alert("CACHE_MISS", "Fetching rate for #{cache_key}")
        Rails.logger.info("[PricingService] CACHE MISS key=#{cache_key}")

        retries = 0
        begin
          rate = Timeout.timeout(5) do
            RateApiClient.get_rate(
              period: @period,
              hotel: @hotel,
              room: @room
            )
          end

          unless rate.success?
            raise StandardError, "API Error: #{rate.body}"
          end

          Rails.logger.info("[PricingService] API RESPONSE: #{rate.body}")
          parsed_rate = JSON.parse(rate.body)
          value = Array(parsed_rate['rates'])
            .detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }
            &.dig('rate')

          unless value
            raise StandardError, "Rate missing in API response"
          end

          Rails.logger.info("[PricingService] WRITING TO CACHE key=#{cache_key} value=#{value}")
          value
        rescue StandardError => e
          if retries < 1
            retries += 1
            Rails.logger.warn("[PricingService] API connection failed. Retrying... (Attempt #{retries})")
            retry
          end
          send_alert("API_ERROR", "Failed to fetch rate for #{cache_key}: #{e.message}")
          Rails.logger.error("[PricingService] RATE API EXCEPTION key=#{cache_key} error=#{e.message}")
          errors << "Pricing Service unavailable. Please retry later for the latest prices."
          next nil
        end
      end

      if was_cached && @result
        send_alert("CACHE_HIT", "Served from cache for #{cache_key}")
        Rails.logger.info("[PricingService] CACHE HIT key=#{cache_key}")
      end

      #log_all_redis_keys

      @result
    end

    private

    def send_alert(type, message)
      # Placeholder for external alerting/monitoring (e.g., Sentry, Datadog, Slack)
      Rails.logger.warn("[ALERT] [#{type}] #{message}")
    end

    def log_all_redis_keys
      unless Rails.cache.respond_to?(:redis)
        Rails.logger.info("[PricingService] Cache is disabled or not using Redis (Current: #{Rails.cache.class}). Run 'rails dev:cache' to enable.")
        return
      end

      redis = Rails.cache.redis
      keys = redis.with { |conn| conn.keys("*") }
      Rails.logger.info("[PricingService] --- CURRENT REDIS KEYS ---")
      if keys.empty?
        Rails.logger.info("  (empty)")
      else
        keys.each do |key|
          raw_value = redis.with { |conn| conn.get(key) }
          value = begin
            obj = Marshal.load(raw_value.force_encoding("ASCII-8BIT"))
            obj.is_a?(ActiveSupport::Cache::Entry) ? obj.value : obj
          rescue
            "Binary data (size: #{raw_value&.bytesize})"
          end
          Rails.logger.info("  Key: #{key} => Value: #{value}")
        end
      end
      Rails.logger.info("[PricingService] --------------------------")
    rescue => e
      Rails.logger.error("[PricingService] Error dumping Redis keys: #{e.message}")
    end
  end
end
