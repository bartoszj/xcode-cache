require "xcode/cache/version"
require 'spaceship'
require 'fileutils'

module XcodeCache

  class Curl
    COOKIES_PATH = Pathname.new('/tmp/xcode-links-cookies.txt')

    def fetch(url, output: "/dev/null", cookie: nil, retries: 3, curl_retries: 3)
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

  class Cacher
    MINIMUM_VERSION = Gem::Version.new('7.0')

    attr_reader :xcodes
    attr_reader :newest

    def xcodes
      @xcodes || fetch_seedlist
    end

    def newest
      @newest || newest_seedlist
    end

    def spaceship
      @spaceship ||= begin
        begin
          Spaceship.login(ENV['XCODE_LINKS_USER'], ENV['XCODE_LINKS_PASSWORD'])
        rescue Spaceship::Client::InvalidUserCredentialsError
          $stderr.puts 'The specified Apple developer account credentials are incorrect.'
          exit(1)
        rescue Spaceship::Client::NoUserCredentialsError
          $stderr.puts <<-HELP
Please provide your Apple developer account credentials via the
XCODE_LINKS_USER and XCODE_LINKS_PASSWORD environment variables.
HELP
          exit(1)
        end

        if ENV.key?('XCODE_LINKS_TEAM_ID')
          Spaceship.client.team_id = ENV['XCODE_LINKS_TEAM_ID']
        end
        Spaceship.client
      end
    end

    def fetch_seedlist
      @xcodes = parse_seedlist(spaceship.send(:request, :post,
                                              '/services-account/QH65B2/downloadws/listDownloads.action').body)

      names = @xcodes.map(&:name)
      @xcodes += prereleases.reject { |pre| names.include?(pre.name) }

      @xcodes
    end

    def newest_seedlist
      xcodes = self.xcodes

      grouped = xcodes.group_by { |x| x.version.to_s.split('.', 3).push('0').slice(0..1).join('.') }
      @newest = grouped.map do |k ,v|
        v.max { |a, b| a.version <=> b.version }
      end

      @newest
    end

    # def xcode_urls
    #   newest.map { |x| x.url }
    # end

    def fetch_xcodes
      newest.each do |xcode|
        puts "Xcode #{xcode.version}"
        Curl.new.fetch(xcode.url, cookie: spaceship.cookie)
      end
    end

    def prereleases
      body = spaceship.send(:request, :get, '/download/').body

      links = body.scan(%r{<a.+?href="(.+?\.(dmg|xip))".*>(.*)</a>})
      links = links.map do |link|
        parent = link[0].scan(%r{path=(/.*/.*/)}).first.first
        match = body.scan(/#{Regexp.quote(parent)}(.+?.pdf)/).first
        if match
          link + [parent + match.first]
        else
          link + [nil]
        end
      end
      links = links.map { |pre| Xcode.new_prerelease(pre[2].strip.gsub(/.*Xcode /, ''), pre[0], pre[3]) }

      if links.count.zero?
        rg = %r{platform-title.*Xcode.* beta.*<\/p>}
        scan = body.scan(rg)

        if scan.count.zero?
          rg = %r{Xcode.* GM.*<\/p>}
          scan = body.scan(rg)
        end

        return [] if scan.empty?

        version = scan.first.gsub(/<.*?>/, '').gsub(/.*Xcode /, '')
        link = body.scan(%r{<button .*"(.+?.xip)".*</button>}).first.first
        notes = body.scan(%r{<a.+?href="(/go/\?id=xcode-.+?)".*>(.*)</a>}).first.first
        links << Xcode.new(version, link, notes)
      end

      links
    end

    def parse_seedlist(seedlist)
      fail Informative, seedlist['resultString'] unless seedlist['resultCode'].eql? 0

      seeds = Array(seedlist['downloads']).select do |t|
        /^Xcode [0-9]/.match(t['name'])
      end

      xcodes = seeds.map { |x| Xcode.new(x) }.reject { |x| x.version < MINIMUM_VERSION }.sort do |a, b|
        a.date_modified <=> b.date_modified
      end

      xcodes.select { |x| x.url.end_with?('.dmg') || x.url.end_with?('.xip') }
    end
  end

  class Xcode
    attr_reader :date_modified
    attr_reader :name
    attr_reader :path
    attr_reader :url
    attr_reader :version
    attr_reader :release_notes_url

    def initialize(json, url = nil, release_notes_url = nil)
      if url.nil?
        @date_modified = json['dateModified'].to_i
        @name = json['name'].gsub(/^Xcode /, '')
        @path = json['files'].first['remotePath']
        url_prefix = 'https://developer.apple.com/devcenter/download.action?path='
        @url = "#{url_prefix}#{@path}"
        @release_notes_url = "#{url_prefix}#{json['release_notes_path']}" if json['release_notes_path']
      else
        @name = json
        @path = url.split('/').last
        url_prefix = 'https://developer.apple.com/'
        @url = "#{url_prefix}#{url}"
        @release_notes_url = "#{url_prefix}#{release_notes_url}"
      end

      begin
        @version = Gem::Version.new(@name.split(' ')[0])
      rescue
        @version = Cacher::MINIMUM_VERSION
      end
    end

    def to_s
      "Xcode #{version} -- #{url}"
    end

    def ==(other)
      date_modified == other.date_modified && name == other.name && path == other.path && \
        url == other.url && version == other.version
    end

    def self.new_prerelease(version, url, release_notes_path)
      new('name' => version,
          'files' => [{ 'remotePath' => url.split('=').last }],
          'release_notes_path' => release_notes_path)
    end
  end
end

f = XcodeCache::Cacher.new
# f.xcodes
# f.newest
# puts f.xcode_urls
f.fetch_xcodes

# require "pry"
# binding.pry

puts "aaa"
