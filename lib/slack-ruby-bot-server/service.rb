module SlackRubyBotServer
  class Service
    include SlackRubyBot::Loggable

    def self.start!
      Thread.new do
        Thread.current.abort_on_exception = true
        instance.start_from_database!
      end
    end

    def self.instance(options = {})
      @instance ||= new(options)
    end

    def initialize(options)
      @lock = Mutex.new
      @services = {}
      @options = { server_class: SlackRubyBotServer::Server }.merge(options)
    end

    def start!(team)
      raise 'Token already known.' if @services.key?(team.token)
      logger.info "Starting team #{team}."
      server = @options[:server_class].new(team: team)
      @lock.synchronize do
        @services[team.token] = server
      end
      restart!(team, server)
    rescue StandardError => e
      logger.error e
    end

    def stop!(team)
      @lock.synchronize do
        raise 'Token unknown.' unless @services.key?(team.token)
        logger.info "Stopping team #{team}."
        @services[team.token].stop!
        @services.delete(team.token)
      end
    rescue StandardError => e
      logger.error e
    end

    def start_from_database!
      Team.active.each do |team|
        start!(team)
      end
    end

    def restart!(team, server, wait = 1)
      server.start_async
    rescue StandardError => e
      case e.message
      when 'account_inactive', 'invalid_auth' then
        logger.error "#{team.name}: #{e.message}, team will be deactivated."
        deactivate!(team)
      else
        logger.error "#{team.name}: #{e.message}, restarting in #{wait} second(s)."
        sleep(wait)
        restart! team, server, [wait * 2, 60].min
      end
    end

    def deactivate!(team)
      team.deactivate!
      @lock.synchronize do
        @services.delete(team.token)
      end
    rescue Mongoid::Errors::Validations => e
      logger.error "#{team.name}: #{e.message}, error - #{e.document.class}, #{e.document.errors.to_hash}, ignored."
    rescue StandardError => e
      logger.error "#{team.name}: #{e.class}, #{e.message}, ignored."
    end

    def reset!
      @services.values.to_a.each do |server|
        stop!(server.team)
      end
    end

    def self.reset!
      @instance.reset! if @instance
      @instance = nil
    end
  end
end
