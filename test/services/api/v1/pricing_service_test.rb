require 'test_helper'
require 'mocha/minitest'

module Api::V1
  class PricingServiceTest < ActiveSupport::TestCase
    setup do
      @period = '2024-10-28'
      @hotel = 'magnificent-resort'
      @room = '1-king-bed'
      @service = PricingService.new(period: @period, hotel: @hotel, room: @room)
      @cache_key = "rate:#{@hotel}:#{@room}:#{@period}"
      Rails.cache.clear
    end

    test "should return from cache on cache hit" do
      Rails.cache.write(@cache_key, 150.0)
      RateApiClient.expects(:get_rate).never
      result = @service.run
      assert_equal 150.0, result
      assert @service.errors.empty?
    end

    test "should call api on cache miss" do
      api_response = mock
      api_response.stubs(:success?).returns(true)
      api_response.stubs(:body).returns({ rates: [{ period: @period, hotel: @hotel, room: @room, rate: 200.0 }] }.to_json)
      RateApiClient.expects(:get_rate).once.returns(api_response)

      result = @service.run

      assert_equal 200.0, result
      assert_equal 200.0, Rails.cache.read(@cache_key)
      assert @service.errors.empty?
    end

    test "should handle API error and retry" do
      RateApiClient.expects(:get_rate).twice.raises(StandardError, "API is down")

      result = @service.run

      assert_nil result
      assert_includes @service.errors, "Pricing Service unavailable. Please retry later for the latest prices."
    end



    test "should handle missing rate in API response" do
      api_response = mock
      api_response.stubs(:success?).returns(true)
      api_response.stubs(:body).returns({ rates: [] }.to_json)
      RateApiClient.expects(:get_rate).once.returns(api_response)

      result = @service.run

      assert_nil result
      assert_includes @service.errors, "Pricing Service unavailable. Please retry later for the latest prices."
    end

    test "should fallback to API if Redis is down" do
      # Simulate Redis failure
      Rails.cache.expects(:fetch).raises(StandardError, "Redis down")

      # Expect API call to succeed despite cache error
      api_response = mock
      api_response.stubs(:success?).returns(true)
      api_response.stubs(:body).returns({ rates: [{ period: @period, hotel: @hotel, room: @room, rate: 200.0 }] }.to_json)
      RateApiClient.expects(:get_rate).once.returns(api_response)

      result = @service.run
      assert_equal 200.0, result
    end
  end
end
