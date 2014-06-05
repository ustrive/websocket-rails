module WebsocketRails
  class Dispatcher

    include Logging

    attr_reader :event_map

    attr_reader :connection_manager

    attr_reader :controller_factory

    attr_reader :message_queue

    attr_reader :processor_registry

    delegate :filtered_channels, to: WebsocketRails

    def initialize(connection_manager)
      @connection_manager = connection_manager
      @controller_factory = ControllerFactory.new(self)
      @event_map          = EventMap.new
      @worker_threads     = WebsocketRails.config.worker_threads
      @message_queue      = EventQueue.new(@worker_threads)
      @processor_registry = MessageProcessors::Registry.new(self).init_processors!
    end

    def dispatch(message)
      @message_queue << message
    end

    def process_inbound
      @message_queue.pop do |message|
        processor_registry.processors_for(message).each do |processor|
          processor.process_message(message)
        end
      end
    end

    def broadcast_message(event)
      connection_manager.connections.map do |_, connection|
        connection.trigger event
      end
    end

    def reload_event_map!
      return unless defined?(Rails) and !Rails.configuration.cache_classes
      begin
        load "#{Rails.root}/config/events.rb"
        @event_map = EventMap.new
      rescue Exception => ex
        log(:warn, "EventMap reload failed: #{ex.message}")
      end
    end

    private

    def route(event)
      actions = []
      event_map.routes_for event do |controller_class, method|
        actions << Fiber.new do
          begin
            log_event(event) do
              controller = controller_factory.new_for_event(event, controller_class, method)

              controller.process_action(method, event)
            end
          rescue Exception => ex
            event.success = false
            event.data = extract_exception_data ex
            event.trigger
          end
        end
      end
      execute actions
    end

    def filter_channel(event)
      actions = []
      actions << Fiber.new do
        begin
          log_event(event) do
            controller_class, catch_all = filtered_channels[event.channel]

            controller = controller_factory.new_for_event(event, controller_class, event.name)
            # send to the method of the event name
            # silently skip routing to the controller on event.name if it doesnt respond
            controller.process_action(event.name, event) if controller.respond_to?(event.name)
            # send to our defined catch all method
            controller.process_action(catch_all, event) if catch_all

          end
        rescue Exception => ex
          event.success = false
          event.data = extract_exception_data ex
          event.trigger
        end
      end if filtered_channels[event.channel]

      actions << Fiber.new{ WebsocketRails[event.channel].trigger_event(event) }
      execute actions
    end

    def execute(actions)
      actions.map do |action|
        EM.next_tick { action.resume }
      end
    end

    def extract_exception_data(ex)
      if record_invalid_defined? and ex.is_a? ActiveRecord::RecordInvalid
        {
          :record => ex.record.attributes,
          :errors => ex.record.errors,
          :full_messages => ex.record.errors.full_messages
        }
      else
        ex if ex.respond_to?(:to_json)
      end
    end

    def record_invalid_defined?
      Object.const_defined?('ActiveRecord') and ActiveRecord.const_defined?('RecordInvalid')
    end


  end
end
