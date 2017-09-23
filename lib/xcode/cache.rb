require 'fileutils'
require 'spaceship'
require 'xcode/cache/version'
require 'xcode/install'

module XcodeCache

  class Curl
    COOKIES_PATH = Pathname.new('/tmp/xcode-links-cookies.txt')

    def fetch(url, output: "/dev/null", cookie: nil, retries: 5, curl_retries: 3)
      # curl --cookie $(cat /tmp/xcode-links-cookies.txt) --cookie-jar /tmp/xcode-links-cookies.txt https://developer.apple.com/devcenter/download.action?path=/Developer_Tools/Xcode_7.1.1/Xcode_7.1.1.dmg -O /dev/null -L
      # curl --cookie $(cat /tmp/xcode-links-cookies.txt) --cookie-jar /tmp/xcode-links-cookies.txt https://developer.apple.com/devcenter/download.action?path=/Developer_Tools/Xcode_7.1.1/Xcode_7.1.1.dmg -O /dev/null -L --progress-bar
      # File.open(COOKIES_PATH, "w") { |file| file.write(spaceship.cookie) }

      options = [
        "--location",
      ]
      retry_options = ['--retry', "#{retries}"]
      command = [
        "curl",
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
    MINIMUM_VERSION = Gem::Version.new('8.3')
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
      @xcodes ||= filtered_xcodes
    end

    def newest_xcodes
      @newest_xcodes || newest_seedlist
    end

    def xcode_urls
      newest_xcodes.map { |x| x.url }
    end

    def fetch_xcodes
      newest_xcodes.each do |xcode|
        puts "Xcode #{xcode.version}"
        Curl.new.fetch(xcode.url, cookie: installer.spaceship.cookie)
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
        Curl.new.fetch(simulator.source)
      end
    end

    private
    def filtered_xcodes
      installer.fetch_seedlist.select { |x| x.version >= MINIMUM_VERSION }.sort { |a, b| b.version <=> a.version }
    end

    def newest_seedlist
      xcodes = self.xcodes

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
      end.flatten.uniq do |xcode|
        xcode.source
      end.sort { |a, b| [a.name.split(' ')[0], b.version] <=> [b.name.split(' ')[0], a.version] }
    end
  end
end

f = XcodeCache::Cacher.new
# puts f.xcode_urls
f.fetch_xcodes

# puts f.simulators_urls
f.fetch_simulators

