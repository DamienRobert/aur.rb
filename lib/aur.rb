require 'aur.rb/version'
require 'net/http'
require 'json'
require 'time'
require 'forwardable'
require 'tsort'
require 'dr/base/utils'
require 'shell_helpers'

module Archlinux
	ArchlinuxError=Class.new(StandardError)
	Utils=::DR::Utils
	Pathname=::DR::Pathname

	def self.delegate_h(klass, var)
		klass.extend(Forwardable)
		methods=[:[], :[]=, :any?, :assoc, :clear, :compact, :compact!, :delete, :delete_if, :dig, :each, :each_key, :each_pair, :each_value, :empty?, :fetch, :fetch_values, :has_key?, :has_value?, :include?, :index, :invert, :keep_if, :key, :key?, :keys, :length, :member?, :merge, :merge!, :rassoc, :reject, :reject!, :select, :select!, :shift, :size, :slice, :store, :to_a, :to_h, :to_s, :transform_keys, :transform_keys!, :transform_values, :transform_values!, :update, :value?, :values, :values_at]
		klass.include(Enumerable)
		klass.send(:def_delegators, var, *methods)
	end

	class Config
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		attr_accessor :opts
		Archlinux.delegate_h(self, :@opts)
		include SH::ShConfig

		def initialize(file, **opts)
			file=Pathname.new(file)
			file=Pathname.new(ENV["XDG_CONFIG_HOME"] || "#{ENV['HOME']}/.config") + file if file.relative?
			file_config= file.readable? ? file.read : '{}'
			wrap=eval("Proc.new { |context| #{file_config} }")
			@opts=default_config.merge(opts)
			@opts.merge!(wrap.call(self))
		end

		def sh_config
			@opts[:sh_config]
		end

		def default_config
			{
				cache: "arch_aur", #where we dl PKGBUILDs
				db: 'aur', #if relative the db will be in cachedir
				aur_url: "https://aur.archlinux.org/", #base aur url
				chroot: "/var/lib/aurbuild/x86_64", #chroot root
				build_chroot: false, #do we use the chroot?
				chroot_update: 'pacman -Syu --noconfirm', #how to update an existing chroot
				sign: true, #can be made more atomic, cf the sign method
				devtools_pacman: "/usr/share/devtools/pacman-extra.conf", #pacman.conf for chroot build
				pacman_conf: "/etc/pacman.conf", #default pacman-conf (for makepkg build)
				sh_config: { #default programs options
					makepkg: {default_opts: ["-crs", "--needed"]},
					makechrootpkg: {default_opts: ["-cu"]},
				},
				view: "vifm -c view! -c tree -c 0",
				git_update: "git pull",
				git_clone: "git clone",
			}
		end

		#:makepkg, :makechrootpkg, :repo (=repo-add, repo-remove)
		def sign(mode)
			opt_sign=@opts[:sign]
			if opt_sign.is_a?(Hash)
				opt_sign[mode]
			else
				opt_sign
			end
		end

		def view(dir)
			view=@opts[:view]
			case view
			when Proc
				view.call(dir)
			else
				success, _rest=SH.sh("#{view} #{dir.shellescape}")
				return success
			end
		end

		def git_update
			method=@opts[:git_update]
			case method
			when Proc
				method.call(dir)
			else
				success, _rest=SH.sh(method)
				return success
			end
		end

		def git_clone(url, dir)
			method=@opts[:git_clone]
			case method
			when Proc
				method.call(url, dir)
			else
				success, _rest=SH.sh("#{method} #{url.shellescape} #{dir.shellescape}")
				return success
			end
		end

		def cachedir
			global_cache=Pathname.new(ENV["XDG_CACHE_HOME"] || "#{ENV['HOME']}/.cache")
			cache=global_cache+@opts[:cache]
			cache.mkpath
			cache
		end

		def setup_pacman_conf(conf)
			pacman=PacmanConf.create(conf)
			aur=self.db(false)
			if aur and !pacman[:repos].include?(aur.repo_name)
				pacman[:repos][aur.repo_name]={Server: ["file://#{URI.escape(aur.dir.to_s)}"]}
			end
			pacman
		end

		def default_pacman_conf
			@default_pacman_conf ||= if (conf=@opts[:pacman_conf])
				PacmanConf.new(conf)
			else
				PacmanConf
			end
		end

		def devtools
			unless @devtools_config
				require 'uri'
				# here we need the raw value, since this will be used by pacstrap
				# which calls pacman --root; so the inferred path for DBPath and so
				# on would not be correct since it is specified
				devtools_pacman=PacmanConf.new(@opts[:devtools_pacman], raw: true)
				# here we need to expand the config, so that Server =
				# file://...$repo...$arch get their real values
				my_pacman=default_pacman_conf
				devtools_pacman[:repos].merge!(my_pacman.non_official_repos)
				setup_pacman_conf(devtools_pacman)
				@devtools_config = Devtools.new(pacman_conf: devtools_pacman)
			end
			@devtools_config
		end

		def makepkg_config
			unless @makepkg_config
				makepkg_pacman=default_pacman_conf
				setup_pacman_conf(makepkg_pacman)
				@makepkg_config = Devtools.new(pacman_conf: makepkg_pacman)
			end
			@makepkg_config
		end

		def db=(name)
			case name
			when DB
				@db=name
			when Pathname
				@db=DB.new(name)
			when String
				if DB.db_file?(name)
					@db=DB.new(name)
				else
					@db=DB.new(cachedir+".db"+"#{name}.db.tar.gz")
				end
			when true
				@db=DB.new(cachedir+".db"+"aur.db.tar.gz")
			when false, nil
				@db=name #false for false, nil to reset
			else
				SH.logger.warn("Database name #{name} not suitable")
				@db=nil
			end
			# reset these so the pacman_conf gets the correct db name
			@makepkg_config=nil
			@devtools_config=nil
		end

		def db(create=true)
			@db.nil? and self.db=@opts[:db]
			if create and @db
				@db.create
			end
			@db
		end

		# if changing a setting, we may need to reset the rest
		def reset
			self.db=nil
		end
	end

	self.singleton_class.attr_accessor :config
	@config=Config.new("aur.rb")

	def self.add_to_hash(h, key, value)
		case h[key]
		when nil
			h[key] = value
		when Array
			h[key] << value
		else
			h[key]=[h[key], value]
		end
	end

	class Version
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		include Comparable
		attr_reader :epoch, :version, :pkgrel
		def initialize(v)
			@v=v
			parse(v)
		end

		private def parse(v)
			if v.nil? or v.empty?
				@epoch=-1 #any version is better than empty version
				@version=Gem::Version.new(0)
				@pkgrel=nil
				return
			end
			epoch, rest = v.split(':', 2)
			if rest.nil?
				rest=epoch; epoch=0
				@real_epoch=false
			else
				@real_epoch=true
			end
			@epoch=epoch
			version, pkgrel=Utils.rsplit(rest, '-', 2)
			version.tr!('+_','.')
			@version=Gem::Version.new(version) rescue Gem::Version.new("0.#{version}")
			@pkgrel=pkgrel
		end
		
		def <=>(w)
			w=self.class.new(w.to_s)
			r= @epoch <=> w.epoch
			if r==0
				r= @version <=> w.version
				if r==0 and @pkgrel and w.pkgrel
					r= @pkgrel <=> w.pkgrel
				end
			end
			r
		end

		def to_s
			@v
			# r=""
			# r << "#{@epoch}:" if @real_epoch
			# r << "#{@version}"
			# r << "-#{@pkgrel}" if @pkgrel
			# r
		end

		# strip version information from a package name
		def self.strip(v)
			v.sub(/[><=]+[\w.\-+:]*$/,'')
		end
	end

	# ex: pacman>=2.0.0
	QueryError=Class.new(ArchlinuxError)
	class Query
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		def self.strip(query)
			self.create(query).name
		end

		include Comparable
		attr_accessor :name, :op, :version, :op2, :version2
		def initialize(query)
			@query=query
			@name, @op, version, @op2, version2=parse(query)
			@version=Version.new(version)
			@version2=Version.new(version2)
		end

		def to_s
			@query
		end

		def max
			strict=false
			if @op=='<=' or @op=='='
				max=@version
			elsif @op=="<"
				max=@version; strict=true
			elsif @op2=="<="
				max=@version2
			elsif @op2=="<"
				max=@version2; strict=true
			end
			return max, strict #nil means Float::INFINITY, ie no restriction
		end

		def min
			strict=false
			if @op=='>=' or @op=='='
				min=@version
			elsif @op==">"
				min=@version; strict=true
			elsif @op2==">="
				min=@version2
			elsif @op2==">"
				min=@version2; strict=true
			end
			return min, strict
		end

		def <=>(other)
			other=self.class.create(other)
			min, strict=self.min
			omin, ostrict=other.min
			return 1 if min==omin and strict
			return -1 if min==omin and ostrict
			min <=> omin
		end

		# here we check if a package can satisfy a query
		# note that other can itself be a query, think of a package that
		# requires foo>=2.0 and bar which provides foo>=3
		# satisfy? is symmetric, it means that the intersection of the
		# available version ranges is non empty
		def satisfy?(other)
			case other
			when Version
				omin=other; omax=other; ominstrict=false; omaxstrict=false
				oname=@name #we assume the name comparison was already done
			else
				other=self.class.create(other)
				omax, omaxstrict=other.max
				omin, ominstrict=other.min
				oname=other.name
			end
			return false unless @name==oname
			min, strict=self.min
			return false if omax and min and (omax < min or omax == min && (strict or omaxstrict))
			max, strict=self.max
			return false if max and omin and (omin > max or omin == max && (strict or ominstrict))
			true
		end

		private def parse(query)
			if (m=query.match(/^([^><=]*)([><=]*)([\w.\-+:]*)([><=]*)([\w.\-+:]*)$/))
				name=m[1]
				op=m[2]
				version=m[3]
				op2=m[4]
				version2=m[5]
				if op.nil?
					name, version=Utils.rsplit(name, '-', 2)
					op="="; op2=nil; version2=nil
				end
				return name, op, version, op2, version2
			else
				raise QueryError.new("Bad query #{query}")
			end
		end
	end

	module AurQuery
		extend self
		attr_accessor :config
		@config=Archlinux.config

		AurQueryError=Class.new(ArchlinuxError)

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
					date=res["date"]
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

	class DB
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		def self.db_file?(name)
			case name
			when Pathname
				true
			when String
				if name.include?('/') or name.match(/\.db(\..*)?$/)
					true
				else
					false #Usually we assume this is a repo name
				end
			end
		end

		attr_accessor :file, :config
		def initialize(file, config: Archlinux.config)
			@file=Pathname.new(file)
			@config=config
		end

		def mkpath
			@file.dirname.mkpath
		end

		def path
			if file.exist?
				file.realpath
			else
				file
			end
		end

		def repo_name
			@file.basename.to_s.sub(/\.db(\..*)?$/,'')
		end

		def create
			mkpath
			unless @file.exist?
				call(:'repo-add', path.shellescape)
			end
			self
		end

		def to_s
			@file.to_s
		end

		# a db is a tar.gz archive of packages/desc, like yay-8.998-1/descr
		def list
			require 'dr/sh'
			res= SH.run_simple("bsdcat #{@file.shellescape}", chomp: :lines) {return nil}
			list=[]; pkg={}; mode=nil
			flush = lambda do
				# catch old deps files which don't specify the full infos
				unless pkg[:name].nil? and pkg[:base].nil?
					pkg[:repo]||=path
					list << pkg 
				end
			end
			res.each do |l|
				next if l.empty? or l.match(/^\u0000*$/)
				if (m=l.match(/(\u0000+.*\u0000+)?%([A-Z0-9]*)%$/))
					mode=m[2].downcase.to_sym
					if m[1] #new db entry
						flush.call #store old db entry
						pkg={}
					end
				else
					l=l.to_i if mode==:csize or mode==:isize
					l=Time.at(l.to_i) if mode==:builddate
					Archlinux.add_to_hash(pkg, mode, l)
				end
			end
			flush.call #don't forget the last one
			list
		end

		def files(absolute=true)
			list.map do |pkg|
				file=Pathname.new(pkg[:filename])
				absolute ? dir + file : file
			end
		end
		# def files
		# 	packages.l.map {|pkg| dir+Pathname.new(pkg[:filename])}
		# end

		def dir
			@file.dirname.realpath
		end

		def call(*args)
			@config.launch(*args) do |*args|
				dir.chdir do
					SH.sh(*args)
				end
			end
		end

		def move_to_db(*files, op: :mv)
			files=files.map {|f| Pathname.new(f).realpath}
			dir=self.dir
			files.map do |f|
				if f.dirname == dir
					f
				else
					new=dir+f.basename
					f.send(op, new)
					new
				end
			end
			files
		end

		def add(*files, cmd: :'repo-add', default_opts:[], sign: @config.sign(:repo), **opts)
			default_opts+=['-s', '-v'] if sign
			default_opts+=['--key', sign] if sign.is_a?(String)
			unless files.empty?
				call(cmd, path.shellescape, *files, default_opts: default_opts, **opts)
			end
		end

		def remove(*args, **opts)
			add(*args, cmd: :'repo-remove', **opts)
		end

		def packages(refresh=false)
			@packages=nil if refresh
			@packages||=PackageList.new(list)
		end

		def dir_packages
			PackageFiles.from_dir(dir).packages
		end

		def package_files
			PackageFiles.new(*files).packages
		end

		def check
			packages.same?(package_files)
		end

		def check_update(other=dir_packages)
			up=self.packages.check_updates(other)
			refresh=up.select {|_k, u| u[:op]==:upgrade or u[:op]==:downgrade}
			add=up.select {|_k, u| u[:op]==:install}
			remove=up.select {|_k, u| u[:op]==:obsolete}
			return {refresh: refresh, add: add, remove: remove}
		end

		def update(other=dir_packages)
			r=check_update(other)
			add(*(r[:refresh].merge(r[:add])).map {|_k,v| other[v[:out_pkg]].file.shellescape})
			# remove(*(r[:remove].map {|_k,v| packages[v[:in_pkg]].file.shellescape}))
			remove(*(r[:remove].map {|_k,v| Query.strip(v[:in_pkg])}))
			r
		end
	end

	class Repo
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		def initialize(name)
			@repo=name
		end

		def list(mode: :pacsift)
			command= case mode
			when :pacman
				"pacman -Slq #{@repo.shellescape}" #returns pkg
			when :pacsift
				"pacsift --exact --repo=#{@repo.shellescape} <&-" #returns repo/pkg
			when :paclist
				"paclist #{@repo.shellescape}" #returns pkg version
			end
			SH.run_simple(command, chomp: :lines) {return nil}
		end

		def packages(refresh=false)
			@packages=nil if refresh
			@packages ||= PackageList.new(self.class.info(*list))
		end

		def self.pacman_info(*pkgs, local: false) #local=true refers to the local db info
			list=[]
			to_list=lambda do |s|
				return [] if s=="None"
				s.split
			end
			# Note: core/pacman only works for -Sddp or -Si, not for -Qi
			# Indeed local/pacman works for pacinfo, but not for pacman (needs
			# the -Q options)
			res=SH.run_simple({'COLUMNS' => '1000'}, "pacman -#{local ? 'Q': 'S'}i #{pkgs.shelljoin}", chomp: :lines)
			key=nil; info={}
			res.each do |l|
				if key==:optional_deps and (m=l.match(/^\s+(\w*):\s+(.*)$/))
					#here we cannot split(':') because we need to check for the leading space
					info[key][m[1]]=m[2]
				else
					key, value=l.split(/\s*:\s*/,2)
					if key.nil? #new package
						list << info; key=nil; info={}
						next
					end
					key=key.strip.downcase.gsub(' ', '_').to_sym
					case key
					when :optional_deps
						dep, reason=value.split(/\s*:\s*/,2)
						value={dep => reason}
					when :groups, :provides, :depends_on, :required_by, :optional_for, :conflicts_with, :replaces
						value=to_list.call(value)
					when :install_script
						value=false if value=="No"
						value=true if value=="Yes"
					when :install_date, :build_date
						value=Time.parse(value)
					end
					info[key]=value
				end
			end
			# no need to add the last info, pacman -Q/Si always end with a new line
			list
		end

		def self.pacinfo(*pkgs) #this refers to the local db info
			list=[]; info={}
			res=SH.run_simple("pacinfo #{pkgs.shelljoin}", chomp: :lines)
			res.each do |l|
				key, value=l.split(/\s*:\s*/,2)
				if key.nil? #next package
					list << info; info={}
					next
				end
				key=key.downcase.gsub(' ', '_').to_sym
				case key
				when :install_script
					value=false if value=="No"
					value=true if value=="Yes"
				when :install_date, :build_date
					value=Time.parse(value)
				end
				Archlinux.add_to_hash(info, key, value)
			end
			# no need to add at the end, pacinfo always end with a new line
			list
		end

		def self.info(*packages)
			if SH.find_executable("pacinfo")
				pacinfo(*packages)
			else
				pacman_info(*packages)
			end
		end

		def self.packages(*packages)
			PackageList.new(info(*packages))
		end
	end

	class PackageFiles
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		attr_accessor :files
		def initialize(*files)
			@files=files.map {|file| DR::Pathname.new(file)}
		end
		
		def infos(slice=200) #the command line should not be too long
			format={
				filename: "%f",
				pkgname: "%n",
				pkgbase: "%e",
				version: "%v",
				url: "%u",
				description: "%d",
				packager: "%p",
				architecture: "%a",
				build_date: "%b",
				download_size: "%k",
				install_size: "%m",
				depends: "%D",
				conflicts: "%H",
				opt_depends: "%O",
				provides: "%P",
				replaces: "%T",
				# format << "%r\n" #repo
			}
			total=format.keys.count
			r=[]; delim="  ,  "
			split=lambda do |l| l.split(delim) end
			@files.each_slice(slice) do |files|
				SH.run_simple("expac --timefmt=%s #{format.values.join("\n").shellescape} -l #{delim.shellescape} -p #{files.shelljoin}", chomp: :lines).each_slice(total).with_index do |l,i|
					info={}
					format.keys.each_with_index do |k, kk|
						value=l[kk]
						value=split[value] if %i(depends conflicts opt_depends provides replaces).include?(k)
						value=nil if k==:pkgbase and value=="(null)"
						value=Time.at(value.to_i) if k==:build_date
						value=value.to_i if k==:download_size or k==:install_size
						info[k]=value if value
					end
					info[:repo]=files[i]
					r<<info
				end
			end
			r
		end

		def packages(refresh=false)
			@packages=nil if refresh
			@packages ||= PackageList.new(self.infos)
		end

		def self.from_dir(dir)
			dir=Pathname.new(dir)
			self.new(*dir.glob('*.pkg.*').map {|g| next if g.to_s.end_with?('~') or g.to_s.end_with?('.sig'); f=dir+g; next unless f.readable?; f}.compact)
		end
	end

	class Makepkg
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		attr_accessor :dir, :base, :env, :config, :asdeps

		def initialize(dir, config: Archlinux.config, env: {}, asdeps: false)
			@dir=DR::Pathname.new(dir)
			@base=@dir.basename
			@config=config
			@env=env
			@asdeps=asdeps
			db=@config.db
			@env['PKGDEST']=db.dir.to_s if db
		end

		def name
			@base.to_s
		end

		def call(*args, run: :run_simple, **opts)
			@config.launch(:makepkg, *args, **opts) do |*args, **opts|
				@dir.chdir do
					SH.public_send(run, @env, *args, **opts)
				end
			end
		end

		def info
			stdin=call("--printsrcinfo", chomp: :lines)
			mode=nil; r={}; current={}; pkgbase=nil; pkgname=nil
			stdin.each do |l|
				key, value=l.split(/\s*=\s*/,2)
				next if key.nil?
				if key=="pkgbase"
					mode=:pkgbase; current[:pkgbase]=value
				elsif key=="pkgname"
					if mode==:pkgbase
						r=current
						r[:pkgs]={repo: @dir}
					else
						r[:pkgs][pkgname]=current
					end
					current={}; mode=:pkgname; pkgname=value
				else
					key=key.strip.to_sym
					Archlinux.add_to_hash(current, key, value)
				end
			end
			r[:pkgs][pkgname]=current #don't forget to update the last one
			r
		end

		def packages(refresh=false)
			@packages=nil if refresh
			unless @packages
				r=info
				pkgs=r.delete(:pkgs)
				r[:pkgbase]
				base=Package.new(r)
				list=pkgs.map do |name, pkg|
					pkg[:name]=name
					Package.new(pkg).merge(base)
				end
				@packages=PackageList.new(list)
			end
			@packages
		end

		def url
			@config[:aur_url]+@base.to_s+".git"
		end

		def get(logdir: nil, view: false)
			#SH.sh("vcs clone_or_update --diff #{url.shellescape} #{@dir.shellescape}")
			if logdir
				logdir=DR::Pathname.new(logdir)
				logdir.mkpath
			end
			if @dir.exist?
				# TODO: what if @dir exist but is not a git directory?
				@dir.chdir do
					unless @config.git_update
						SH.logger.error("Error in updating #{@dir}")
					end
					if logdir
						SH::VirtualFile.new("orderfile", "PKGBUILD").create(true) do |tmp|
							patch=SH.run_simple("git diff -O#{tmp} HEAD@{1}")
							(logdir+"#{@dir.basename}.patch").write(patch) unless patch.empty?
							(logdir+"#{@dir.basename}").on_ln_s(@dir.realpath, rm: :symlink)
						end
					end
				end
			else
				unless @config.git_clone(url, @dir)
					SH.logger.error("Error in cloning #{url} to #{@dir}")
				end
				SH.sh("git clone #{url.shellescape} #{@dir.shellescape}")
				if logdir
					(logdir+"!#{@dir.basename}").on_ln_s(@dir.realpath)
				end
			end
			if view
				return @config.view(@dir)
			else
				return true
			end
		end

		# raw call to makepkg
		def makepkg(*args, **opts)
			call(*args, run: :sh, **opts)
		end

		def make(*args, sign: config.sign(:makepkg), default_opts: [], force: false, asdeps: @asdeps, **opts)
			default_opts << "--sign" if sign
			default_opts << "--key=#{sign}" if sign.is_a?(String)
			default_opts << "--force" if force
			default_opts << "--asdeps" if asdeps

			tools=@config.makepkg_config #this set up pacman and makepkg config files
			success=false
			@dir.chdir do
				success=tools.makepkg(*args, default_opts: default_opts, env: @env, **opts)
			end
			success
		end

		def mkarchroot
			@config.devtools.mkarchroot("base-devel")
		end

		def makechroot(*args, sign: @config.sign(:makechrootpkg), force: false, **opts)
			unless force
				if list.all? {|f| f.exist?}
					SH.logger.info "Skipping #{@dir} since it is already built (use force=trye to override)"
					return false
				end
			end
			devtools=@config.devtools
			success=false
			@dir.chdir do
				success=devtools.makechrootpkg(*args, env: @env, **opts)
			end
			self.sign(sign) if sign and success
			success
		end

		def add_to_db(db=@config.db)
			SH.logger.warn "Bad database #{db}" unless db.is_a?(DB)
			db.add(*list.select {|l| l.exist?})
		end

		def build(*makepkg_args, mkarchroot: false, chroot: @config[:build_chroot], **opts)
			SH.logger.info "=> Building #{@dir}"
			if chroot
				self.mkarchroot if mkarchroot
				success, _r=makechroot(*makepkg_args, **opts)
			else
				success, _r=make(*makepkg_args, **opts)
			end
			if success and (db=@config.db)
				add_to_db(db)
				if !chroot #sync db
					tools=@config.makepkg_config
					tools.sync_db(db.repo_name)
				end
			end
		end

		def install(*args, view: true, **opts)
			r=get(view: view)
			build(*args, **opts) if r
		end

		def list(**opts)
			call("--packagelist", chomp: :lines, err: "/dev/null", **opts).map {|f| Pathname.new(f)}
		end

		def sign(sign, **opts)
			list(**opts).each do |pkg|
				if pkg.file?
					if (sig=Pathname.new("#{pkg}.sig")).file?
						SH.logger.warn "Signature #{sig} already exits, skipping"
					else
						SH.sh("gpg #{sign.is_a?(String) ? "-u #{sign}" : ""} --detach-sign --no-armor #{pkg.shellescape}") 
					end
				end
			end
		end

	end

	class MakepkgList
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		Archlinux.delegate_h(self, :@l)
		attr_accessor :config, :cache, :l

		def initialize(l, config: Archlinux.config, cache: config.cachedir)
			@config=config
			@cache=Pathname.new(cache)
			@l={}
			l.each do |m| 
				unless m.is_a?(Makepkg)
					m=Pathname.new(m)
					m = @cache+m if m.relative?
					v=Makepkg.new(m, config: @config)
					@l[v.name]=v
				end
			end
		end

		def packages(refresh=false)
			@packages = nil if refresh
			@packages ||= @l.values.reduce do |list, makepkg|
				list.merge(makepkg.packages)
			end
		end

		def get(*args, view: true)
			Dir.mktmpdir("aur_view") do |d|
				@l.values.each do |l|
					l.get(*args, logdir: d)
				end
				if view
					return @config.view(d)
				else
					return true
				end
			end
		end

		def make(*args)
			@l.values.each do |l|
				l.make(*args)
			end
		end

		def makechroot(*args)
			@l.values.each do |l|
				l.makechroot(*args)
			end
		end

		def mkarchroot
			@config.devtools.mkarchroot("base-devel")
		end

		def list
			@l.values.flat_map { |l| l.list }
		end

		def add_to_db(db=@config.db)
			SH.logger.warn "Bad database #{db}" unless db.is_a?(DB)
			db.add(*list.select {|l| l.exist?})
		end

		def build(*args, chroot: @config[:build_chroot], **opts)
			mkarchroot if chroot
			@l.values.each do |l|
				l.build(*args, chroot: chroot, **opts)
			end
		end

		def install(*args, view: true, **opts)
			r=get(view: view)
			build(*args, **opts) if r
		end
	end

	PackageError=Class.new(ArchlinuxError)
	class Package
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		Archlinux.delegate_h(self, :@props)
		attr_reader :name, :props

		def initialize(*args)
			case args.length
			when 2
				name, props=args
			when 1
				props=args.first
				name=nil
			else
				raise PackageError.new("Error the number of arguments should be 1 or 2")
			end
			@name=name
			@props={}
			self.props=(props)
			@name=@props[:name] || @props[:pkgname] || @props[:pkgbase] unless @name
		end

		def props=(props)
			[:groups, :depends, :make_depends, :check_depends, :conflicts, :replaces, :provides, :depends_for, :opt_depends_for].each do |k|
				props.key?(k) or @props[k]=[]
			end
			@props[:opt_depends]||={}
			props.each do |k,v|
				k=Utils.to_snake_case(k.to_s).to_sym
				k=:opt_depends if k==:optdepends || k==:optional_deps
				k=:make_depends if k==:makedepends
				k=:check_depends if k==:checkdepends
				k=:build_date if k==:checkdepends
				k=:depends if k==:depends_on or k==:requires
				k=:conflicts if k==:conflicts_with
				k=:pkgbase if k==:base
				k=:depends_for if k==:required_by
				k=:opt_depends_for if k==:optional_for
				k=:description if k==:desc
				case k
				when :first_submitted, :last_modified, :out_of_date, :build_date, :install_date
					if v and !v.is_a?(Time)
						v= v.is_a?(Integer) ? Time.at(v) : Time.parse(v)
					end
				when :repository, :groups, :depends, :make_depends, :check_depends, :conflicts, :replaces, :provides, :depends_for, :opt_depends_for
					v=Array(v)
				when :opt_depends
					unless v.is_a?(Hash)
						w={}
						Array(v).each do |l|
							l.match(/(\w*)\s+:\s+(.*)/) do |m|
								w[m[1]]=m[2]
							end
						end
						v=w
					end
				end
				@props[k]=v
			end
		end

		def merge(h)
			h.each do |k,v|
				if @props[k].nil? or ((k==:package_size or k==:download_size or k==:installed_size) and (@props[k]=="0.00 B" or @props[k]==0))
					@props[k]=v
				elsif k==:repository
					@props[k]=(Array(@props[k])+v).uniq
				end
			end
			self
		end

		def dependencies(l=%i(depends))
			l.map {|i| a=@props[i]; a.is_a?(Hash) ? a.keys : Array(a)}.flatten.uniq
		end

		def version
			Version.new(@props[:version])
		end

		def name_version
			r=self.name
			version=self.version
			r+="="+version.to_s if version
			r
		end

		def file
			Pathname.new(@props[:filename])
		end

		def same?(other)
			# @props.slice(*(@props.keys - [:repo])) == other.props.slice(*(other.props.keys - [:repo]))
			slice=%i(version description depends provides opt_depends replaces conflicts)
			# p name, other.name, @props.slice(*slice), other.props.slice(*slice)
			name == other.name && @props.slice(*slice) == other.props.slice(*slice)
		end
	end

	class PackageList
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		Archlinux.delegate_h(self, :@l)
		attr_accessor :children_mode, :ext_query
		attr_reader :l, :versions, :provides_for

		def initialize(list)
			@l={}
			@versions={} #hash of versions for quick look ups
			@provides_for={} #hash of provides for quick look ups
			@ext_query=nil #how to get missing packages, default
			@children_mode=%i(depends) #children, default
			@ignore=[] #ignore packages update
			@query_ignore=[] #query ignore packages (ie these won't be returned by a query)
			merge(list)
		end

		def packages
			@versions.keys
		end

		def name_of(pkg)
			pkg.name_version
		end

		def same?(other)
			unless @l.keys == other.keys
				SH.logger.warn("Inconsistency in the package names")
				return false
			end
			r=true
			@l.each do |name, pkg|
				unless pkg.same?(other[name])
					SH.logger.warn("Inconsistensy for the package #{name}")
					r=false
				end
			end
			return r
		end

		def merge(l)
			# l=l.values if l.is_a?(PackageList) # this is handled below
			l= case l
				when Hash
					l.values.compact
				when PackageList
					l.values
				else
					l.to_a
				end
			l.each do |pkg|
				pkg=Package.new(pkg) unless pkg.is_a?(Package)
				name=name_of(pkg)
				if @l.key?(name)
					@l[name].merge(pkg)
				else
					@l[name]=pkg
				end

				@versions[pkg.name]||={}
				@versions[pkg.name][pkg.version.to_s]=name

				pkg[:provides].each do |p|
					pkg=Query.strip(p)
					@provides_for[pkg]||={}
					@provides_for[pkg][p]=name #todo: do we pass the name or the full pkg?
				end
			end
			self
		end

		def latest
			r={}
			@versions.each do |pkg, versions|
				v=versions.keys.max do |v1,v2|
					Version.create(v1) <=> Version.create(v2)
				end
				r[pkg]=@l[versions[v]]
			end
			r
		end

		def find(q, **opts)
			return q if @l.key?(q)
			q=Query.create(q); pkg=q.name
			query(q, **opts) do |found, type|
				if type==:version
					unless found.empty? #we select the most up to date
						max = found.max { |v,w| Version.create(v) <=> Version.create(w) }
						return @versions[pkg][max]
					end
				elsif type==:provides
					max = found.max { |v,w| Query.create(v) <=> Query.create(w) }
					return @provides_for[pkg][max]
				end
			end
			return nil
		end

		def query(q, provides: false, &b) #provides: do we check Provides?
			q=Query.new(q) unless q.is_a?(Query)
			matches=[]; pkg=q.name
			if @versions.key?(pkg)
				matches+=(found=@versions[pkg].keys.select {|v| q.satisfy?(Version.create(v))}).map {|k| @versions[pkg][k]}
				yield(found, :version) if block_given?
			end
			if provides and @provides_for.key?(pkg)
				matches+=(found=@provides_for[pkg].keys.select {|v| q.satisfy?(Query.create(v))}).map {|k| @provides_for[pkg][k]}
				yield(found, :provides) if block_given?
			end
			matches
		end

		def to_a
			@l.values
		end

		# here the arguments are Strings
		# return the arguments replaced by eventual provides + missing packages
		# are added to @l
		def resolve(*queries, provides: true, ext_query: @ext_query, fallback: true, **opts)
			got={}; missed=[]
			pkgs=queries.map {|p| Query.strip(p)}
			ignored = pkgs & @query_ignore
			queries.each do |query|
				if ignored.include?(Query.strip(query))
					got[query]=nil #=> means the query was ignored
				else
					pkg=self.find(query, provides: provides, **opts)
					if pkg
						got[query]=pkg
					else
						missed << query
					end
				end
			end
			# we do it this way to call ext_query in batch
			if ext_query and !missed.empty?
				found, new_pkgs=ext_query.call(*missed, provides: provides)
				self.merge(new_pkgs)
				got.merge!(found)
				missed-=found.keys
			end
			if fallback and !missed.empty?
				new_queries={}
				missed.each do |query|
					if (query_pkg=Query.strip(query)) != query
						new_queries[query]=query_pkg
						# missed.delete(query)
					end
				end
				unless new_queries.empty?
					SH.logger.warn "Trying fallback for packages: #{new_queries.keys.join(', ')}"
					fallback_got=self.resolve(*new_queries.values, provides: provides, ext_query: ext_query, fallback: false, **opts)
					got.merge!(fallback_got)
					SH.logger.warn "Missing packages: #{missed.map {|m| r=m; r<<" [fallback: #{fallback}]" if (fallback=fallback_got[new_queries[m]]); r}.join(', ')}"
				end
			else
				SH.logger.warn "Missing packages: #{missed.join(', ')}" if !missed.empty? and ext_query != false #ext_query=false is a hack to silence this message
			end
			got
		end

		def get(*args)
			#compact because the resolution can be nil for an ignored package
			resolve(*args).values.compact
		end

		def children(node, mode=@children_mode, verbose: false, **opts, &b)
			deps=@l.fetch(node).dependencies(mode)
			SH.logger.info "- #{node} => #{deps}" if verbose
			deps=get(*deps, **opts)
			SH.logger.info " => #{deps}" if verbose
			if b
				deps.each(&b)
			else
				deps
			end
		end

		private def call_tsort(l, method: :tsort, **opts, &b)
			each_node=l.method(:each)
			s=self
			each_child = lambda do |node, &b|
				s.children(node, **opts, &b)
			end
			TSort.public_send(method, each_node, each_child, &b)
		end

		def tsort(l, **opts, &b)
			if b
				call_tsort(l, method: :each_strongly_connected_component, **opts, &b)
			else
				r=call_tsort(l, method: :strongly_connected_components, **opts)
				cycles=r.select {|c| c.length > 1}
				SH.logger.warn "Cycles detected: #{cycles}" unless cycles.empty?
				r.flatten
			end
		end

		# recursive get
		def rget(*pkgs)
			l=get(*pkgs)
			tsort(l)
		end

		# check updates compared to another list
		def check_updates(l)
			l=self.class.create(l)
			a=self.latest; b=l.latest
			r={}
			b.each do |k, v|
				if a.key?(k)
					v1=a[k].version
					v2=v.version
					h={in: v1.to_s, out: v2.to_s, in_pkg: name_of(a[k]), out_pkg: name_of(v)}
					case v1 <=> v2
					when -1
						h[:op]=:upgrade
					when 0
						h[:op]=:equal
					when 1
						h[:op]=:downgrade
					end
					r[k]=h
				else
					#new installation
					r[k]={op: :install,
						in: nil,
						out: v.version.to_s, out_pkg: name_of(v)}
				end
			end
			(a.keys-b.keys).each do |k|
				r[k]={op: :obsolete,
					in: a[k].version.to_s,
					out: nil, in_pkg: name_of(a[k])}
			end
			r
		end

		def select_updates(r)
			r.select {|_k,v| v[:op]==:upgrade or v[:op]==:install}.map {|_k, v| v[:out_pkg]}
		end

		def get_updates(l, verbose: true, obsolete: true)
			c=check_updates(l)
			show_updates(c, obsolete: obsolete) if verbose
			select_updates(c)
		end

		#take the result of check_updates and pretty print them
		def show_updates(r, obsolete: true)
			require 'simplecolor'
			r.each do |k,v|
				next if v[:op]==:equal
				next if obsolete and v[:op]==:obsolete
				vin= v[:in] ? v[:in] : "(none)"
				vout= v[:out] ? v[:out] : "(none)"
				op = "->"; op="<-" if v[:op]==:downgrade
				extra=""
				extra=" [#{v[:op]}]" if v[:op]!=:upgrade
				SH.logger.info SimpleColor.color("  -> #{k}: #{vin} #{op} #{vout}#{extra}", :black)
			end
		end

		def check_update(ext_query=@ext_query)
			if ext_query
				_found, new_pkgs=ext_query.call(*packages)
				check_updates(new_pkgs)
			end
		end

		def update(**opts)
			install(update: true, **opts)
		end

		# take a list of packages to install
		def install(*packages, update: false, ext_query: @ext_query, verbose: true, obsolete: true)
			packages+=self.packages if update
			if ext_query
				_found, new_pkgs=ext_query.call(*packages)
				SH.logger.info "# Checking packages" if verbose
				u=get_updates(new_pkgs, verbose: verbose, obsolete: obsolete)
				new=self.class.new(l.values).merge(new_pkgs)
				# The updates or new packages may need new deps
				SH.logger.info "# Checking dependencies" if verbose
				full=new.rget(*u)
				full_updates=get_updates(new.values_at(*full), verbose: verbose, obsolete: obsolete)
				yield u, full_updates if block_given?
				full_updates
			else
				SH.logger.warn "External query not defined"
			end
		end
	end

	class AurCache < PackageList
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		def initialize(l)
			super
			@ext_query=method(:ext_query)
			@query_ignore=AurPackageList.official
		end

		def ext_query(*queries, provides: false)
			pkgs=queries.map {|p| Query.strip(p)}
			# in a query like foo>1000, even if foo exist and was queried,
			# the query fails so it gets called in ext_query
			# remove these packages
			# TODO: do the same for a provides query
			pkgs-=self.packages
			if pkgs.empty?
				l=self.class.new([])
			else
				SH.logger.warn "! Calling aur for infos on: #{pkgs.join(', ')}"
				l=AurQuery.packages(*pkgs)
				@query_ignore += pkgs - l.packages #these don't exist in aur
			end
			r=l.resolve(*queries, ext_query: false, fallback: false)
			return r, l
		end
	end

	class AurPackageList < PackageList
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end

		def self.official
			@official||=%w(core extra community).map {|repo| Repo.new(repo).list(mode: :pacman)}.flatten.compact
		end

		def self.cache
			@cache ||= AurCache.new([])
		end

		def initialize(l)
			super
			@missed=[]
			@ext_query=method(:ext_query)
			@children_mode=%i(depends make_depends check_depends)
		end

		def official
			self.class.official
		end

		def ext_query(*queries, provides: false)
			cache=self.class.cache
			got=cache.resolve(*queries, fallback: false, provides: provides)
			return got, self.class.new(cache.l.slice(*got.values.compact))
		end

		def do_update(**opts, &b)
			do_install(update: true, **opts)
		end

		def do_install(*args, **opts)
			install_opts={}
			%i(update ext_query verbose obsolete).each do |key|
				opts.key?(key) && install_opts[key]=opts.delete(key)
			end
			deps=[]
			l=install(*args, **install_opts) do |orig, with_deps|
				deps=with_deps-orig
			end
			unless l.empty?
				m=MakepkgList.new(l.map {|p| Query.strip(p)})
				deps.each { |dep| m[Query.strip(dep)]&.asdeps=true }
				if block_given?
					yield m 
				else
					m.install(**opts)
				end
				m
			end
		end
	end

	class PacmanConf
		def self.create(v)
			v.is_a?(self) ? v : self.new(v, {}) #pass empty keywords so that a Hash is seen as an argument and not a list of keywords
		end

		Archlinux.delegate_h(self, :@pacman_conf)
		attr_accessor :pacman_conf, :config

		def initialize(conf="/etc/pacman.conf", config: Archlinux.config, **keys)
			@config=config
			if conf.is_a?(String) or conf.is_a?(Pathname)
				conf=parse(conf, **keys)
			end
			@pacman_conf=conf
		end

		def self.parse(content)
			list=%i(HoldPkg IgnorePkg IgnoreGroup NoUpgrade NoExtract SigLevel LocalFileSigLevel RemoteFileSigLevel Usage Server)
			mode=:options
			config={options: {}, repos: {}}
			content=content.each_line if content.is_a?(String)
			content.each do |l|
				if (m=l.match(/^\[([\w-]+)\]$/))
					mode=m[1]
					if mode == "options"
						mode=:options 
					else
						config[:repos][mode]||={}
					end
				else
					key, value=l.split(' = ', 2)
					key=key.to_sym
					h =  mode==:options ? config[:options] : config[:repos][mode]
					if list.include?(key)
						h[key]||=[]
						h[key]<<value
					else
						h[key]=value
					end
				end
			end
			config
		end

		def parse(file, raw: false, args: nil)
			unless args
				if raw
					args=[:'pacconf', "--raw", "--config=#{file}"]
				else
					args=[:'pacman-conf', "--config=#{file}"]
				end
			end
			output=@config.launch(*args) do |*args|
				SH.run_simple(*args, chomp: :lines)
			end
			self.class.parse(output)
		end

		def non_official_repos
			repos=@pacman_conf[:repos]
			repos.slice(*(repos.keys - %i(core extra community multilib testing community-testing multilib-testing)))
		end

		def to_s
			r=[]
			print_values=lambda do |h, section|
				r<<"[#{section}]" if section
				h.each do |k,v|
					case v
					when nil
						r << k
					when Array
						v.each { |vv| r << "#{k} = #{vv}" }
					else
						r << "#{k} = #{v}"
					end
				end
			end
			print_values.call(@pacman_conf[:options], "options")
			@pacman_conf[:repos].each do |section, props|
				print_values.call(props, section)
			end
			r.join("\n")+"\n"
		end

		def tempfile
			SH::VirtualFile.new("pacman.conf", to_s)
		end
	end

	class Devtools
		def self.create(v)
			v.is_a?(self) ? v : self.new(v)
		end
		Archlinux.delegate_h(self, :@opts)

		attr_accessor :config, :opts
		def initialize(config: Archlinux.config, **opts)
			@config=config
			@opts=@config.opts.merge(opts)
			# %i(pacman_conf makepkg_conf).each do |key|
			# 	@opts[key]=@opts[key].tempfile.file if @opts[key].respond_to?(:tempfile)
			# end
			@opts[:chroot]=Pathname.new(@opts[:chroot]) if @opts[:chroot]
			add_binds
		end

		def add_binds
			require 'uri'
			if (conf=@opts[:pacman_conf]).is_a?(PacmanConf)
				conf[:repos].each do |_name, opts|
					opts[:Server].each do |server|
						server.match(%r!file://(.*)!) do |m|
							@opts[:bind_ro]||=[]
							@opts[:bind_ro] << URI.unescape(m[1])
						end
					end
				end
			end
		end

		def files
			%i(pacman_conf makepkg_conf).each do |key|
				if @opts[key]
					file=@opts[key]
					file=file.tempfile.file if file.respond_to?(:tempfile)
					yield key, file
				end
			end
		end

		def pacman_config
			Pacman.create(@opts[:pacman_conf])
		end

		def pacman(*args, default_opts: [], **opts)
			files do |key, file|
				default_opts += ["--config", file] if key==:pacman_conf
			end
			@config.launch(:pacman, *args, default_opts: default_opts, **opts) do |*args|
				SH.sh(*args)
			end
		end

		def makepkg(*args, default_opts: [], **opts)
			files do |key, file|
				# trick to pass options to pacman
				args << "PACMAN_OPTS+=--config=#{file.shellescape}"
				default_opts += ["--config", file] if key==:makepkg_conf
			end
			@config.launch(:makepkg, *args, default_opts: default_opts, **opts) do |*args|
				SH.sh(*args)
			end
		end


		def nspawn(*args, root: @opts[:chroot]+'root', default_opts: [], **opts)
			files do |key, file|
				default_opts += ["-C", file] if key==:pacman_conf
				default_opts += ["-M", file] if key==:makepkg_conf
			end
			if (binds_ro=@opts[:bind_ro])
				binds_ro.each do |b|
					args.unshift("--bind-ro=#{b}")
				end
			end
			if (binds_rw=@opts[:bind_rw])
				binds_rw.each do |b|
					args.unshift("--bind=#{b}")
				end
			end
			args.unshift root

			@config.launch(:'arch-nspawn', *args, default_opts: default_opts, **opts) do |*args|
				SH.sh(*args)
			end
		end

		# this takes the same options as nspawn
		def mkarchroot(*args, nspawn: @config[:chroot_update], default_opts: [], **opts)
			files do |key, file|
				default_opts += ["-C", file] if key==:pacman_conf
				default_opts += ["-M", file] if key==:makepkg_conf
			end
			chroot=@opts[:chroot]
			chroot.sudo_mkpath unless chroot.directory?
			args.unshift(chroot+'root')
			if (chroot+'root'+'.arch-chroot').file?
				# Note that if nspawn is not called (and the chroot does not
				# exist), then the passed pacman.conf will not be replace the one
				# in the chroot. And when makechrootpkg calls nspawn, it does not
				# transmit the -C/-M options. So even if we don't want to update,
				# we should call a dummy bin like 'true'
				if nspawn
					nspawn=nspawn.shellsplit if nspawn.is_a?(String)
					self.nspawn(*nspawn, **opts)
				end
			else
				@config.launch(:mkarchroot, *args, default_opts: default_opts, escape: true, **opts) do |*args|
					SH.sh(*args)
				end
			end
		end

		def makechrootpkg(*args, default_opts: [], **opts)
			default_opts+=['-r', @opts[:chroot]]
			if (binds_ro=@opts[:bind_ro])
				binds_ro.each do |b|
					default_opts += ["-D", b]
				end
			end
			if (binds_rw=@opts[:bind_rw])
				binds_rw.each do |b|
					default_opts += ["-d", b]
				end
			end

			#makechrootpkg calls itself with sudo --preserve-env=SOURCE_DATE_EPOCH,GNUPGHOME so it does not keep PKGDEST..., work around this by providing our own sudo
			@config.launch(:makechrootpkg, *args, default_opts: default_opts, sudo: 'sudo --preserve-env=GNUPGHOME,PKGDEST,SOURCE_DATE_EPOCH', **opts) do |*args|
				SH.sh(*args)
			end
		end

		def tmp_pacman(conf, **opts)
			PacmanConf.create(conf).tempfile.create(true) do |file|
				pacman=lambda do |*args, **pac_opts|
					@config.launch(:pacman, *args, default_opts: ["--config", file], **opts.merge(pac_opts)) do |*args|
						SH.sh(*args)
					end
				end
				yield pacman, file
			end
		end

		def sync_db(*names)
			conf=PacmanConf.create(@opts[:pacman_conf])
			new_conf={options: conf[:options], repos: {}}
			repos=conf[:repos]
			names.each do |name|
				if repos[name]
					new_conf[:repos][name]=repos[name]
				else
					SH.logger.warn "sync_db: unknown repo #{name}"
				end
			end
			tmp_pacman(new_conf) do |pacman|
				if block_given?
					yield(pacman)
				else
					pacman['-Syu', sudo: true]
				end
			end
		end

	end
end

=begin
aur=Archlinux::AurPackageList.new([])
l=aur.install("pacaur")

aur=Archlinux::AurPackageList.new(Archlinux.config.db.packages)
aur.do_update
=end

# TODO:
# --devel
# aur provides
# @ignore
