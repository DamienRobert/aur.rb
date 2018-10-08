require 'json'
require 'time'
require 'net/http'
require 'aur/config'
require 'aur/packages'

module Archlinux

	AurQueryError=Class.new(ArchlinuxError)

	module AurQuery
		extend self
		attr_accessor :config
		@config=Archlinux.config

		# AurQuery.query(type: "info", arg: pacaur)
		# AurQuery.query(type: "info", :"arg[]" => %w(cower pacaur))
		# AurQuery.query(type: "search", by: "name", arg: "aur")
		#  by  name (search by package name only)
  	#      *name-desc* (search by package name and description)
  	#      maintainer (search by package maintainer)
  	#      depends (search for packages that depend on keywords)
  	#      makedepends (search for packages that makedepend on keywords)
  	#      optdepends (search for packages that optdepend on keywords)
  	#      checkdepends (search for packages that checkdepend on keywords)
  	# => search result:
  	#  {"ID"=>514909,
  	#  "Name"=>"pacaur",
  	#  "PackageBaseID"=>49145,
  	#  "PackageBase"=>"pacaur",
  	#  "Version"=>"4.7.90-1",
  	#  "Description"=>"An AUR helper that minimizes user interaction",
  	#  "URL"=>"https://github.com/rmarquis/pacaur",
  	#  "NumVotes"=>1107,
  	#  "Popularity"=>7.382043,
  	#  "OutOfDate"=>nil,
  	#  "Maintainer"=>"Spyhawk",
  	#  "FirstSubmitted"=>1305666963,
  	#  "LastModified"=>1527690065,
  	#  "URLPath"=>"/cgit/aur.git/snapshot/pacaur.tar.gz"},
  	# => info result adds:
  	#  "Depends"=>["cower", "expac", "sudo", "git"],
  	#  "MakeDepends"=>["perl"],
  	#  "License"=>["ISC"],
  	#  "Keywords"=>["AUR", "helper", "wrapper"]}]

		def query(h)
			uri=URI("#{@config[:aur_url]}/rpc/")
			params = {v:5}.merge(h)
			uri.query = URI.encode_www_form(params)
			res = Net::HTTP.get_response(uri)
			if res.is_a?(Net::HTTPSuccess)
				r= res.body 
			else
				raise AurQueryError.new("AUR: Got error response for query #{h}")
			end
			data = JSON.parse(r)
			case data['type']
			when 'error'
				raise AurQueryError.new("Error: #{data['results']}")
			when 'search','info','multiinfo'
				return data['results']
			else
				raise AurQueryError.new("Error in response data #{data}")
			end
		end

		# Outdated packages: Aur.search(nil, by: "maintainer")
		def search(arg, by: nil)
			r={type: "search", arg: arg}
			r[:by]=by if by
			# if :by is not specified, aur defaults to name-desc
			self.query(r)
		end

		def infos(*pkgs, slice: 150)
			search=[]
			pkgs.each_slice(slice) do |pkgs_slice|
				r={type: "info", :"arg[]" => pkgs_slice}
				search+=self.query(r)
			end
			search.each { |pkg| pkg[:repo]=:aur }
			search
		end

		# try to use infos if possible
		def info(pkg)
			r={type: "info", arg: pkg}
			self.query(r).first
		end

		def packages(*pkgs, klass: AurPackageList)
			klass.new(infos(*pkgs))
		end

		def pkglist(type="packages", delay: 3600, query: :auto) #type=pkgbase
			require 'zlib'
			cache=self.cachedir
			file=cache+"#{type}.gz"
			in_epoch=nil
			if file.exist?
				# intime=file.read.each_line.first
				file.open do |io|
					Zlib::GzipReader.wrap(io) do |gz|
						intime=gz.each_line.first
						intime.match(/^# AUR package list, generated on (.*)/) do |m|
							in_epoch=Time.parse(m[1]).to_i
						end
					end
				end
			end
			if query
				Net::HTTP.get_response(URI("#{@config[:aur_url]}/#{type}.gz")) do |res|
					date=res["date"] #There are no 'Last-Modified' field, cf https://bugs.archlinux.org/task/49092
					update=true
					if date
						epoch=Time.parse(date).to_i
						update=false if epoch and in_epoch and (epoch-in_epoch < delay) and !query==true
					end
					if update
						file.open('w') do |io|
							Zlib::GzipWriter.wrap(io) do |gz|
								res.read_body(gz)
							end
						end
					end
				end
			end
			file.open do |io|
				Zlib::GzipReader.wrap(io) do |gz|
					return gz.each_line.map(&:chomp).drop(1)
				end
			end
		end
	end

	# aur query but with a local config parameter
	class AurQueryCustom
		extend CreateHelper

		def initialize(config: AurQuery.config)
			@config=config
		end

		def packages(*pkgs)
			@config.to_packages(infos(*pkgs))
		end
	end
end
