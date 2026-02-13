# require 'securerandom'
# require 'timeout'

# module Api::V1
#   class PricingService < BaseService
#     def initialize(period:, hotel:, room:)
#       @period = period
#       @hotel = hotel
#       @room = room
#     end

#     def run
#       cache_key = "rate:#{@hotel}:#{@room}:#{@period}"

#       # 1. Fast path: Check cache
#       if (value = Rails.cache.read(cache_key))
#         log_cache_hit(cache_key)
#         return @result = value
#       end

#       # 2. Coalescing logic (only if Redis is available)
#       if Rails.cache.respond_to?(:redis)
#         return @result = fetch_with_coalescing(cache_key)
#       end

#       # 3. Fallback for non-Redis stores (e.g. test env)
#       @result = fetch_and_cache(cache_key)
#     end

#     private

#     def fetch_with_coalescing(cache_key)
#       lock_key = "lock:#{cache_key}"
#       channel_key = "updates:#{cache_key}"
#       heartbeat_key = "heartbeat:#{cache_key}"
#       token = SecureRandom.uuid
#       start_time = Time.now

#       # 1. Try to acquire lock (Non-blocking, single attempt)
#       lock_acquired = false
#       Rails.cache.redis.with do |conn|
#         lock_acquired = conn.set(lock_key, token, nx: true, ex: 15)
#       end

#       if lock_acquired
#         # --- LEADER ---
#         Rails.logger.info("[PricingService] Lock acquired. Fetching...")
        
#         # Start Heartbeat
#         heartbeat_thread = Thread.new do
#           loop do
#             sleep 1
#             Rails.cache.redis.with { |c| c.set(heartbeat_key, Time.now.to_f, ex: 5) }
#           end
#         end

#         begin
#           # Double-check cache
#           if (value = Rails.cache.read(cache_key))
#             log_cache_hit(cache_key)
#             Rails.cache.redis.with { |c| c.publish(channel_key, "done") }
#             return value
#           end

#           # Initial heartbeat
#           Rails.cache.redis.with { |c| c.set(heartbeat_key, Time.now.to_f, ex: 5) }

#           result = fetch_and_cache(cache_key)
          
#           # Notify followers
#           Rails.cache.redis.with { |c| c.publish(channel_key, "done") }
#           return result
#         ensure
#           heartbeat_thread.kill
#           # Safe unlock
#           script = 'if redis.call("get", KEYS[1]) == ARGV[1] then return redis.call("del", KEYS[1]) else return 0 end'
#           Rails.cache.redis.with { |conn| conn.eval(script, keys: [lock_key], argv: [token]) }
#           Rails.cache.redis.with { |conn| conn.del(heartbeat_key) }
#         end
#       else
#         # --- FOLLOWER ---
#         Rails.logger.info("[PricingService] Waiting for leader via Pub/Sub...")
        
#         loop do
#           if Time.now - start_time > 10
#             Rails.logger.warn("[PricingService] Total timeout waiting for leader")
#             break
#           end

#           # Check Heartbeat
#           last_beat = Rails.cache.redis.with { |c| c.get(heartbeat_key) }
#           if last_beat && Time.now.to_f - last_beat.to_f > 3.0
#             Rails.logger.warn("[PricingService] Leader heartbeat stopped. Taking over.")
#             break
#           end

#           begin
#             Timeout.timeout(2) do
#               Rails.cache.redis.with do |conn|
#                 conn.subscribe(channel_key) do |on|
#                   on.subscribe do
#                     if Rails.cache.exist?(cache_key)
#                       conn.unsubscribe
#                     end
#                   end
#                   on.message do
#                     conn.unsubscribe
#                   end
#                 end
#               end
#             end
#           rescue Timeout::Error
#             # Continue loop to check heartbeat
#           end

#           if (value = Rails.cache.read(cache_key))
#             Rails.logger.info("[PricingService] Waited #{(Time.now - start_time).round(3)}s for coalesced result")
#             log_cache_hit(cache_key)
#             return value
#           end
#         end

#         # If still missing, fallback to fetching
#         return fetch_and_cache(cache_key)
#       end
#     end

#     def fetch_and_cache(cache_key)
#       send_alert("CACHE_MISS", "Fetching rate for #{cache_key}")
#       Rails.logger.info("[PricingService] CACHE MISS key=#{cache_key}")

#       retries = 0
#       begin
#         rate = Timeout.timeout(5) do
#           RateApiClient.get_rate(
#             period: @period,
#             hotel: @hotel,
#             room: @room
#           )
#         end

#         unless rate.success?
#           raise StandardError, "API Error: #{rate.body}"
#         end
#         parsed_rate = JSON.parse(rate.body)
#         value = Array(parsed_rate['rates'])
#           .detect { |r| r['period'] == @period && r['hotel'] == @hotel && r['room'] == @room }
#           &.dig('rate')

#         unless value
#           raise StandardError, "Rate missing in API response"
#         end

#         Rails.logger.info("[PricingService] WRITING TO CACHE key=#{cache_key} value=#{value}")
#         Rails.cache.write(cache_key, value, expires_in: 5.minutes)
#         value
#       rescue StandardError => e
#         if retries < 1
#           retries += 1
#           Rails.logger.warn("[PricingService] API connection failed. Retrying... (Attempt #{retries})")
#           retry
#         end
#         send_alert("API_ERROR", "Failed to fetch rate for #{cache_key}: #{e.message}")
#         Rails.logger.error("[PricingService] RATE API EXCEPTION key=#{cache_key} error=#{e.message}")
#         errors << "Pricing Service unavailable. Please retry later for the latest prices."
#         nil
#       end
#     end

#     def log_cache_hit(cache_key)
#       send_alert("CACHE_HIT", "Served from cache for #{cache_key}")
#       Rails.logger.info("[PricingService] CACHE HIT key=#{cache_key}")
#     end

#     def send_alert(type, message)
#       # Placeholder for external alerting/monitoring (e.g., Sentry, Datadog, Slack)
#       Rails.logger.warn("[ALERT] [#{type}] #{message}")
#     end

#     def log_all_redis_keys
#       unless Rails.cache.respond_to?(:redis)
#         Rails.logger.info("[PricingService] Cache is disabled or not using Redis (Current: #{Rails.cache.class}). Run 'rails dev:cache' to enable.")
#         return
#       end

#       redis = Rails.cache.redis
#       keys = redis.with { |conn| conn.keys("*") }
#       Rails.logger.info("[PricingService] --- CURRENT REDIS KEYS ---")
#       if keys.empty?
#         Rails.logger.info("  (empty)")
#       else
#         keys.each do |key|
#           raw_value = redis.with { |conn| conn.get(key) }
#           value = begin
#             obj = Marshal.load(raw_value.force_encoding("ASCII-8BIT"))
#             obj.is_a?(ActiveSupport::Cache::Entry) ? obj.value : obj
#           rescue
#             "Binary data (size: #{raw_value&.bytesize})"
#           end
#           Rails.logger.info("  Key: #{key} => Value: #{value}")
#         end
#       end
#       Rails.logger.info("[PricingService] --------------------------")
#     rescue => e
#       Rails.logger.error("[PricingService] Error dumping Redis keys: #{e.message}")
#     end
#   end
# end