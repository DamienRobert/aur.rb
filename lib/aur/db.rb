require 'aur/config'
require 'aur/packages'
require 'time'

module Archlinux
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
			# @packages||=PackageList.new(list, config: @config)
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
end
