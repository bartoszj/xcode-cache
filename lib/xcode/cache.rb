require 'fileutils'
require 'spaceship'
require 'xcode/cache/version'
require 'xcode/install'

module XcodeCache

  module Downloader

    def self.downloader(support_cookies)
      if support_cookies
        return Curl
      else
        if File.exist?("/usr/local/opt/curl/bin/curl")
          return Curl
        elsif File.exist?("/usr/local/bin/wget")
          return Wget
        else
          return Curl
        end
      end
    end
  end

  class Wget
    def fetch(url, output: "/dev/null", cookie: nil, retries: 5, wget_retries: 3)
      command = [
        "wget",
        "--tries", "#{retries}",
        "--continue",
        "--quiet",
        "--show-progress",
        "--output-document", output,
        url
      ].map(&:to_s)

      wget_retries.times do
        io = IO.popen(command)
        io.each { |line| puts line }
        io.close

        exit_code = $?.exitstatus
        return exit_code.zero?
      end
    end
  end

  class Curl

    COOKIES_PATH = Pathname.new('/tmp/xcode-links-cookies.txt')

    def fetch(url, output: "/dev/null", cookie: nil, retries: 5, curl_retries: 3)
      # curl --cookie $(cat /tmp/xcode-links-cookies.txt) --cookie-jar /tmp/xcode-links-cookies.txt https://developer.apple.com/devcenter/download.action?path=/Developer_Tools/Xcode_7.1.1/Xcode_7.1.1.dmg -O /dev/null -L
      # curl --cookie $(cat /tmp/xcode-links-cookies.txt) --cookie-jar /tmp/xcode-links-cookies.txt https://developer.apple.com/devcenter/download.action?path=/Developer_Tools/Xcode_7.1.1/Xcode_7.1.1.dmg -O /dev/null -L --progress-bar
      # File.open(COOKIES_PATH, "w") { |file| file.write(spaceship.cookie) }

      curl_path = File.exist?("/usr/local/opt/curl/bin/curl") ? "/usr/local/opt/curl/bin/curl" : "curl"

      options = [
        "--location",
      ]
      retry_options = ['--retry', "#{retries}"]
      command = [
        curl_path,
        *options,
        *retry_options,
        '--continue-at', '-',
        "--cookie", cookie,
        "--cookie-jar", COOKIES_PATH,
        "--output", output,
        "--progress-bar",
        # "--verbose",
        url
      ].map(&:to_s)

      # Run the curl command in a loop, retry when curl exit status is 18
      # "Partial file. Only a part of the file was transferred."
      # https://curl.haxx.se/mail/archive-2008-07/0098.html
      curl_retries.times do
        io = IO.popen(command)
        io.each { |line| puts line }
        io.close

        exit_code = $?.exitstatus
        return exit_code.zero? unless exit_code == 18
      end
    ensure
      FileUtils.rm_f(COOKIES_PATH)
    end
  end

  class Installer < XcodeInstall::Installer
    def spaceship
      @spaceship ||= begin
        begin
          Spaceship.login(ENV['XCODE_CACHE_USER'], ENV['XCODE_CACHE_PASSWORD'])
        rescue Spaceship::Client::InvalidUserCredentialsError
          $stderr.puts 'The specified Apple developer account credentials are incorrect.'
          exit(1)
        rescue Spaceship::Client::NoUserCredentialsError
          $stderr.puts <<-HELP
Please provide your Apple developer account credentials via the
XCODE_CACHE_USER and XCODE_CACHE_PASSWORD environment variables.
HELP
          exit(1)
        end

        if ENV.key?('XCODE_CACHE_TEAM_ID')
          Spaceship.client.team_id = ENV['XCODE_CACHE_TEAM_ID']
        end
        Spaceship.client
      end
    end

    def fetch_seedlist
      super
    end
  end

  class Cacher
    XCODE_MINIMUM_VERSION = Gem::Version.new('10.0')
    XCODE_MINIMUM_IOS_VERSION = Gem::Version.new('10.2')
    XCODE_MINIMUM_TVOS_VERSION = Gem::Version.new('10.2')
    XCODE_MINIMUM_WATCHOS_VERSION = Gem::Version.new('4.2')
    GROUP_VERSION_SEGMENTS = 2
    NEWSET_VERSION_COUNT = 2

    attr_reader :installer
    attr_reader :xcodes
    attr_reader :newest_xcodes
    attr_reader :simulators

    def initialize
      @installer = Installer.new
    end

    def xcodes
      @xcodes ||= get_all_xcodes
    end

    def newest_xcodes
      @newest_xcodes || get_newest_xcodes
    end

    def xcode_urls
      newest_xcodes.map { |x| x.url }
    end

    def fetch_xcodes
      newest_xcodes.each do |xcode|
        puts "Xcode #{xcode.version}"
        Downloader::downloader(true).new.fetch(xcode.url, cookie: installer.spaceship.cookie)
      end
    end

    def simulators
      @simulators ||= get_simulators
    end

    def simulators_urls
      simulators.map { |s| s.source }
    end

    def fetch_simulators
      simulators.each do |simulator|
        puts "#{simulator.name}"
        Downloader::downloader(false).new.fetch(simulator.source)
      end
    end

    private
    def get_all_xcodes
      installer.fetch_seedlist.sort { |a, b| b.version <=> a.version }
    end

    def get_newest_xcodes
      # Filter only newset xcodes
      xcodes = self.xcodes.select { |x| x.version >= XCODE_MINIMUM_VERSION }

      # Group by a version numbers
      grouped = xcodes.group_by { |x| x.version.to_s.split('.').push('0').slice(0..GROUP_VERSION_SEGMENTS-1).join('.') }

      # Select only newset versions from a group
      @newest_xcodes = grouped.map do |k ,v|
        v.max(NEWSET_VERSION_COUNT) { |a, b| a.version <=> b.version }
      end.flatten.sort { |a, b| b.version <=> a.version }

      @newest_xcodes
    end

    def get_simulators
      installer.installed_versions.map do |xcode|
        xcode.available_simulators
      end.flatten.select do |simulator|
        name = simulator.name.split(' ')[0]
        case name
        when "iOS"
          simulator.version >= XCODE_MINIMUM_IOS_VERSION
        when "tvOS"
          simulator.version >= XCODE_MINIMUM_TVOS_VERSION
        when "watchOS"
          simulator.version >= XCODE_MINIMUM_WATCHOS_VERSION
        end
      end.uniq do |simulator|
        simulator.source
      end.sort { |a, b| [a.name.split(' ')[0], b.version] <=> [b.name.split(' ')[0], a.version] }
    end
  end
end

f = XcodeCache::Cacher.new
# puts f.xcode_urls
f.fetch_xcodes

# puts f.simulators_urls
f.fetch_simulators

