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

      begin
        @result = Rails.cache.fetch(cache_key, expires_in: 5.minutes, skip_nil: true) do
          was_cached = false
          fetch_from_api(cache_key)
        end
      rescue => e
        Rails.logger.error("[PricingService] Cache error: #{e.message}. Falling back to API.")
        was_cached = false
        @result = fetch_from_api(cache_key)
      end

      if was_cached && @result
        send_alert("CACHE_HIT", "Served from cache for #{cache_key}")
        increment_prometheus_counter("pricing_service_cache_hit")
        Rails.logger.info("[PricingService] CACHE HIT key=#{cache_key}")
      end

      @result
    end

    private

    def fetch_from_api(cache_key)
      send_alert("CACHE_MISS", "Fetching rate for #{cache_key}")
      increment_prometheus_counter("pricing_service_cache_miss")
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
        increment_prometheus_counter("pricing_service_api_success")
        value
      rescue StandardError => e
        if retries < 1
          retries += 1
          Rails.logger.warn("[PricingService] API connection failed. Retrying... (Attempt #{retries})")
          increment_prometheus_counter("pricing_service_api_retry")
          retry
        end
        send_alert("API_ERROR", "Failed to fetch rate for #{cache_key}: #{e.message}")
        increment_prometheus_counter("pricing_service_api_failure")
        Rails.logger.error("[PricingService] RATE API EXCEPTION key=#{cache_key} error=#{e.message}")
        errors << "Pricing Service unavailable. Please retry later for the latest prices."
        nil
      end
    end

    def send_alert(type, message)
      # Placeholder for external alerting/monitoring (e.g., Sentry, Datadog, Slack)
      Rails.logger.warn("[ALERT] [#{type}] #{message}")
    end

    def increment_prometheus_counter(event)
      return unless defined?(PrometheusExporter::Client)

      counter = PrometheusExporter::Client.default.register(
        :counter,
        "pricing_service_events_total",
        "Total events in PricingService"
      )
      counter.observe(1, event: event, hotel: @hotel, room: @room, period: @period)
    rescue => e
      Rails.logger.warn("Failed to send prometheus event: #{e.message}")
    end
  end
end
