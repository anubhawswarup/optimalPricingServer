require 'prometheus_exporter/client'
require 'prometheus_exporter/instrumentation'

if defined?(PrometheusExporter::Instrumentation)
  # Configure the client to point to the exporter container (default to localhost for non-docker)
  host = ENV.fetch("PROMETHEUS_EXPORTER_HOST", "localhost")
  PrometheusExporter::Client.default = PrometheusExporter::Client.new(host: host, port: 9394)

  # Collect process metrics (Heap, GC, Memory, etc.)
  PrometheusExporter::Instrumentation::Process.start(type: "web")

  # Optional: Collect ActiveRecord metrics if using a database
  # PrometheusExporter::Instrumentation::ActiveRecord.start
end
