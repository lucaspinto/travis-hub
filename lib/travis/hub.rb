require 'multi_json'
require 'hashr'
require 'benchmark'
require 'metriks'
require 'core_ext/module/include'
# require 'airbrake'
require 'travis'
require 'travis/support'
require 'travis/hub/async'
require 'travis/hub/instrumentation'

$stdout.sync = true

module Travis
  class Hub
    autoload :Handler,    'travis/hub/handler'
    autoload :Monitoring, 'travis/hub/monitoring'

    include Logging

    class << self
      def start
        setup
        prune_workers
        # cleanup_jobs
        new.subscribe
      end

      def prune_workers
        run_periodically(Travis.config.workers.prune.interval, &::Worker.method(:prune))
      end

      def cleanup_jobs
        run_periodically(Travis.config.jobs.retry.interval, &::Job.method(:cleanup))
      end

      protected

        def setup
          # Airbrake.configure { |config| config.api_key = Travis.config.airbrake.key }
          Database.connect
          Travis::Mailer.setup
          Monitoring.start
          Travis.logger.level = Logger::INFO
        end

        def run_periodically(interval, &block)
          Thread.new do
            loop do
              block.call
              sleep(interval)
            end
          end
        end
    end

    include do
      def initialize
        Travis::Amqp.config = Travis.config.amqp
      end

      def subscribe
        info 'Subscribing to amqp ...'

        subscribe_to_reporting
        subscribe_to_worker_status
      end

      def subscribe_to_reporting
        queue_names  = Travis.config.queues.map { |queue| queue[:queue] }
        queue_names += ['builds.common', 'builds.configure']

        queue_names.uniq.each do |name|
          Travis::Amqp::Consumer.jobs(name).subscribe(:ack => true, &method(:receive))
        end
      end

      def subscribe_to_worker_status
        Travis::Amqp::Consumer.workers.subscribe(:ack => true, &method(:receive))
      end

      def receive(message, payload)
        info "[#{Thread.current.object_id}] Handling event #{message.properties.type.inspect} with payload : #{(payload.size > 160 ? "#{payload[0..160]} ..." : payload)}"

        with(:benchmarking, :caching) do
          if payload = decode(payload)
            event = message.properties.type
            handler = Handler.for(event, payload)
            handler.handle
          end
        end

        message.ack
      rescue Exception => e
        puts e.message, e.backtrace
        message.ack
        # notify_airbrake(e)
        # message.reject(:requeue => false) # how to decide whether to requeue the message?
      end

      protected

        def with(*methods, &block)
          if methods.size > 1
            head = methods.shift
            with(*methods) { send(head, &block) }
          else
            send(methods.first, &block)
          end
        end

        def benchmarking(&block)
          timing = Benchmark.realtime(&block)
          info "[#{Thread.current.object_id}] Completed in #{timing.round(4)} seconds"
        end

        def caching(&block)
          ActiveRecord::Base.cache(&block)
        end

        def decode(payload)
          MultiJson.decode(payload)
        rescue
          nil
        end

        # def notify_airbrake(exception)
        #   unless ['test', 'development'].include?(Travis.config.env)
        #     Airbrake.notify(exception)
        #   end
        # rescue Exception => e
        #   puts e.message, e.backtrace
        # end
    end
  end
end
