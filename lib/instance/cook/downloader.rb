#
# Copyright (c) 2009-2012 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

module RightScale

  # Abstract download capabilities
  class Downloader

    class ConnectionException < Exception; end
    class DownloadException < Exception; end

    include RightSupport::Log::Mixin

    # (Integer) Size in bytes of last successful download (nil if none)
    attr_reader :size

    # (Integer) Speed in bytes/seconds of last successful download (nil if none)
    attr_reader :speed

    # (String) Last resource downloaded
    attr_reader :sanitized_resource

    # Hash of IP Address => Hostname
    attr_reader :ips

    # Initializes a Downloader with a list of hostnames
    #
    # The purpose of this method is to instantiate a Downloader
    #
    # === Parameters
    # @param <[String]> Hostnames to resolve
    #
    # === Return
    # @return [Downloader]

    def initialize(hostnames)
      raise ArgumentError, "At least one hostname must be provided" if hostnames.empty?
      hostnames = [hostnames] unless hostnames.respond_to?(:each)
      @ips = resolve(hostnames)
    end

    # Wraps the download implementation of the subclass
    #
    # The purpose of this method is to perform some generic functionality
    # around the actual download method call
    #
    # === Parameters
    # @param [String] Resource URI to parse and fetch
    # @param [String] Destination for fetched resource
    #
    # === Return
    # @return [File] The file that was downloaded

    def download(resource, dest)
      @size = 0
      @speed = 0
      @sanitized_resource = sanitize_resource(resource)
      t0 = Time.now

      file = _download(resource, dest)

      @speed = size / (Time.now - t0)
      return file
    end

    # Message summarizing last successful download details
    #
    # === Return
    # @return [String] Message with last downloaded resource, download size and speed

    def details
      "Downloaded '#{@sanitized_resource}' (#{ scale(size.to_i).join(' ') }) at #{ scale(speed.to_i).join(' ') }/s"
    end

    protected

    # Resolve a list of hostnames to a hash of Hostname => IP Addresses
    #
    # The purpose of this method is to lookup all IP addresses per hostname and
    # build a lookup hash that maps IP addresses back to their original hostname
    # so we can perform TLS hostname verification.
    #
    # === Parameters
    # @param <[String]> Hostnames to resolve
    #
    # === Return
    # @return [Hash]
    #   * :key [<String>] a key (IP Address) that accepts a hostname string as it's value

    def resolve(hostnames)
      ips = {}
      hostnames.each do |hostname|
        infos = nil
        begin
          infos = Socket.getaddrinfo(hostname, 443, Socket::AF_INET, Socket::SOCK_STREAM, Socket::IPPROTO_TCP)
        rescue Exception => e
          logger.error "Failed to resolve hostnames: #{e.class.name}: #{e.message}"
          raise e
        end

        # Randomly permute the addrinfos of each hostname to help spread load.
        infos.shuffle.each do |info|
          ip = info[3]
          ips[ip] = hostname
        end
      end
      ips
    end

    # Parse Exception message and return it
    #
    # The purpose of this method is to parse the message portion of RequestBalancer
    # Exceptions to determine the actual Exceptions that resulted in all endpoints
    # failing to return a non-Exception.
    #
    # === Parameters
    # @param [Exception] Exception to parse

    # === Return
    # @return [String] List of Exceptions

    def parse(e)
      if e.kind_of?(RightSupport::Net::NoResult)
        message = e.message.split("Exceptions: ")[1]
      else
        message = e.class.name
      end
      message
    end

    # Create and return a RequestBalancer instance
    #
    # The purpose of this method is to create a RequestBalancer that will be used
    # to service all 'download' requests.  Once a valid endpoint is found, the
    # balancer will 'stick' with it. It will consider a response of '408: RequestTimeout' and
    # '500: InternalServerError' as retryable exceptions and all other HTTP error codes to
    # indicate a fatal exception that should abort the load-balanced request
    #
    # === Return
    # @return [RightSupport::Net::RequestBalancer]

    def balancer
      @balancer ||= RightSupport::Net::RequestBalancer.new(
          ips.keys,
          :policy => RightSupport::Net::Balancing::StickyPolicy,
          :fatal  => lambda do |e|
            if RightSupport::Net::RequestBalancer::DEFAULT_FATAL_EXCEPTIONS.any? { |c| e.is_a?(c) }
              true
            elsif e.respond_to?(:http_code) && (e.http_code != nil)
              (e.http_code >= 400 && e.http_code < 500) && (e.http_code != 408 && e.http_code != 500 )
            else
              false
            end
          end
      )
    end

    # Returns a path to a CA file
    #
    # The CA bundle is a basically static collection of trusted certs of top-level CAs.
    # It should be provided by the OS, but because of our cross-platform nature and
    # the lib we're using, we need to supply our own. We stole curl's.
    #
    # === Return
    # @return [String] Path to a CA file

    def get_ca_file
      ca_file = File.normalize_path(File.join(File.dirname(__FILE__), 'ca-bundle.crt'))
    end

    # Instantiates an HTTP Client
    #
    # The purpose of this method is to create an HTTP Client that will be used to
    # make requests in the download method
    #
    # === Return
    # @return [RightSupport::Net::HTTPClient]

    def get_http_client
      RightSupport::Net::HTTPClient.new({:headers => {:user_agent => "RightLink v#{AgentConfig.protocol_version}"}})
    end

    # Return a sanitized value from given argument
    #
    # The purpose of this method is to return a value that can be securely
    # displayed in logs and audits
    #
    # === Parameters
    # @param [String] 'Resource' to parse
    #
    # === Return
    # @return [String] 'Resource' portion of resource provided

    def sanitize_resource(resource)
      logger.info "[ryan] Resource: #{resource}, #{resource.split('?')}"
      resource.split('?').first
    end

    # Return scale and scaled value from given argument
    #
    # The purpose of this method is to convert bytes to a nicer format for display
    # Scale can be B, KB, MB or GB
    #
    # === Parameters
    # @param [Integer] Value in bytes
    #
    # === Return
    # @return <[Integer], [String]> First element is scaled value, second element is scale

    def scale(value)
      case value
        when 0..1023
          [value, 'B']
        when 1024..1024**2 - 1
          [value / 1024, 'KB']
        when 1024^2..1024**3 - 1
          [value / 1024**2, 'MB']
        else
          [value / 1024**3, 'GB']
      end
    end

  end

end