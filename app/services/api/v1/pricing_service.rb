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
        Rails.logger.info("[PricingService] CACHE MISS key=#{cache_key}")
        rate = RateApiClient.get_rate(
          period: @period,
          hotel: @hotel,
          room: @room
        )

        if rate.success?
          parsed_rate = JSON.parse(rate.body)
          value = parsed_rate['rates']
            .detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }
            &.dig('rate')

          if value
            Rails.logger.info("[PricingService] WRITING TO CACHE key=#{cache_key} value=#{value}")
          end

          value
        else
          Rails.logger.error(
            "[PricingService] RATE API FAILURE key=#{cache_key} error=#{rate.body}"
          )
          errors << rate.body['error']
          nil
        end
      end

      if was_cached && @result
        Rails.logger.info("[PricingService] CACHE HIT key=#{cache_key}")
      end

      log_all_redis_keys

      @result
    end

    private

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
