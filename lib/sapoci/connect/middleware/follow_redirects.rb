require 'faraday'
require 'set'
require 'webrick'

module SAPOCI
  module Connect
    module Middleware
      # Public: Exception thrown when the maximum amount of requests is exceeded.
      class RedirectLimitReached < Faraday::Error::ClientError
        attr_reader :response

        def initialize(response)
          super "too many redirects; last one to: #{response['location']}"
          @response = response
        end
      end

      # Public: Exception thrown when client returns an empty location header
      class RedirectWithoutLocation < Faraday::Error::ClientError
        attr_reader :response

        def initialize(response)
          super "redirect with empty location header"
          @response = response
        end
      end

      # Public: Follow HTTP 301, 302, 303, and 307 redirects for GET, PATCH, POST,
      # PUT, and DELETE requests.
      #
      # This middleware does not follow the HTTP specification for HTTP 302, by
      # default, in that it follows the improper implementation used by most major
      # web browsers which forces the redirected request to become a GET request
      # regardless of the original request method.
      #
      # For HTTP 301, 302, and 303, the original request is transformed into a
      # GET request to the response Location, by default. However, with standards
      # compliance enabled, a 302 will instead act in accordance with the HTTP
      # specification, which will replay the original request to the received
      # Location, just as with a 307.
      #
      # For HTTP 307, the original request is replayed to the response Location,
      # including original HTTP request method (GET, POST, PUT, DELETE, PATCH),
      # original headers, and original body.
      #
      # This middleware currently only works with synchronous requests; in other
      # words, it doesn't support parallelism.
      class FollowRedirects < Faraday::Middleware
        # HTTP methods for which 30x redirects can be followed
        ALLOWED_METHODS = Set.new [:get, :post, :put, :patch, :delete]
        # HTTP redirect status codes that this middleware implements
        REDIRECT_CODES  = Set.new [301, 302, 303, 307]
        # Keys in env hash which will get cleared between requests
        ENV_TO_CLEAR    = Set.new [:status, :response, :response_headers]

        # Default value for max redirects followed
        FOLLOW_LIMIT = 3

        # Public: Initialize the middleware.
        #
        # options - An options Hash (default: {}):
        #           limit - A Numeric redirect limit (default: 3)
        #           standards_compliant - A Boolean indicating whether to respect
        #                                 the HTTP spec when following 302
        #                                 (default: false)
        def initialize(app, options = {})
          super(app)
          @options = options

          @options[:cookies] = :all
          @cookies = []

          @replay_request_codes = Set.new [307]
          @replay_request_codes << 302 if standards_compliant?
        end

        def call(env)
          perform_with_redirection(env, follow_limit)
        end

        private

        def transform_into_get?(response)
          !@replay_request_codes.include? response.status
        end

        def perform_with_redirection(env, follows)
          request_body = env[:body]
          response = @app.call(env)

          response.on_complete do |env|
            if follow_redirect?(env, response)
              raise RedirectLimitReached, response if follows.zero?
              env = update_env(env, request_body, response)
              response = perform_with_redirection(env, follows - 1)
            end
          end
          response
        end

        def update_env(env, request_body, response)
          location = response['location']
          raise RedirectWithoutLocation, response if location.to_s.size == 0
          env[:url] += location
          
          if @options[:cookies] && cookie_string = collect_cookies(env)
            env[:request_headers]['Cookie'] = cookie_string
          end

          if transform_into_get?(response)
            env[:method] = :get
            env[:body] = nil
          else
            env[:body] = request_body
          end

          ENV_TO_CLEAR.each {|key| env.delete key }

          env
        end

        def follow_redirect?(env, response)
          ALLOWED_METHODS.include? env[:method] and
            REDIRECT_CODES.include? response.status
        end

        def follow_limit
          @options.fetch(:limit, FOLLOW_LIMIT)
        end

        def collect_cookies(env)
          if response_cookies = env[:response_headers]['Set-Cookie']
            @cookies = WEBrick::Cookie.parse_set_cookies(response_cookies)
            @cookies.inject([]) do |result, cookie|
              # TODO only send back cookies where path is nil or 
              # path matches according to env[:url]
              result << cookie.name + "=" + cookie.value
            end.uniq.join(";")
          else
            nil
          end
        end

        def standards_compliant?
          @options.fetch(:standards_compliant, false)
        end
      end
    end
  end
end

