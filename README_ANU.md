# Optimal Pricing Server
# optimalPricingServer
This server caches prices for upto 5 mins to reduce the pressure on the model runs thereby maximising savings for the cost of maintenance.
This document outlines the recent additions to the Optimal Pricing Server, specifically focusing on the implementation of Redis caching for the pricing service.

## Caching Logic for Ratings API

To optimize performance and reduce latency, we have introduced a caching layer using Redis before making calls to the external Ratings API. This mechanism helps us serve pricing information faster and minimizes redundant API requests.

### Workflow

1.  **Cache Key Generation**: For each pricing request, a unique cache key is generated using the `hotel`, `room`, and `period` parameters. The format of the key is `rate:<hotel>:<room>:<period>`.

2.  **Cache Lookup**: Before making a call to the `RateApiClient`, the system first checks if a valid entry exists in the Redis cache for the generated key.

3.  **Cache Hit**: If a cached value is found (a "cache hit"), the pricing information is retrieved directly from Redis and returned to the client. This avoids the need for an external API call. The log will show a `CACHE HIT` message.

4.  **Cache Miss**: If no cached value is found (a "cache miss"), the system proceeds to call the `RateApiClient` to fetch the current rate.
    - Upon a successful API response, the retrieved rate is stored in the Redis cache with an expiration time of 5 minutes.
    - The fresh rate is then returned to the client.
    - The log will show a `CACHE MISS` message, followed by a `WRITING TO CACHE` message.

5.  **Error Handling**: If the `RateApiClient` call fails, an error is logged, and no value is written to the cache.

### Redis Key Logging

For debugging and monitoring purposes, the service includes a method (`log_all_redis_keys`) that logs all keys currently stored in the Redis cache. This helps in understanding the cache's state at any given time.
