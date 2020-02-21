== Release v0.2.0 (2020-02-21) ==

	* TODO++
	* TODO.md
	* config: fix sign_names
	* config: use devtools makepkg in chroot
	* pre build: pre sign an empty files to initialize keyring
	* DR::URI is now DR::URIEscape
	* Use back URI.escape (via a wrapper to disable warnings)
	* Ruby 2.7 warning fixes
	* Fixes for ruby 2.7
	* Update for ruby 2.7
	* packages: add @get() and @rget()
	* config.rb: Bug fix
	* Default packages: allow customisations
	* cli: pkgs compare
	* Bug fixes
	* cli: aur.rb pkgs list ...
	* Bug fix
	* cli: db list, db rm
	* better update infos
	* db: clean up update code
	* aur.rb: TODO + fix db rm bug
	* cli: Add devtools commands
	* cli: aur search => allow multiple terms
	* cli: --no-chroot, --local
	* makepkg: get list of built packages for post_install callback
	* cli: --install/--no-install option
	* Add build command
	* config: use PPHelper
	* Distinguish package list class from an install package list class
	* Split packages into install_packages
	* DB#clean_obsolete
	* PackageFiles#rm_pkgs
	* Documentation updates
	* Doc updates
	* Bug fixes, DB#show_updates
	* Improve messages
	* Fix verbosity level
	* Fix logger invocations for new SH.logger api
	* cli: use standard log options
	* Logger: color mode
	* Gemspec: add metadata
	* Update Rakefile
	* cli: sign
	* TODO++
	* Verbosity
	* pretty_print: don't expand Config
	* sign: bug fixes (+ reduce verbosity of exec)
	* db: Move sig files
	* makepkg: resign files when rebuilding
	* repos.rb: clean return the paths too
	* config.rb: post_install now install correct (updated) version
	* packages.rb: fix --rebuild=true
	* makepkg.rb: improve visibility of logging
	* cli.rb: --verbose
	* More debug informations
	* cli.rb: debug and log level
	* db: allow to return PackageFiles rather than Packages
	* PackageFiles#clean
	* add_to_db: bug fixes
	* DB#add_to_db
	* post_install: call with list of packages success
	* cli.rb: --devel switch
	* makepkg.rb: we need to use `reset --hard`
	* packages.rb: Bug fix in AurMakepkgCache
	* Add debug statements
	* TODO++
	* Helpers: create_class
	* db.rb: use realdirpath and fallback to abs path
	* cli.rb: `db update`
	* A package already built is a success
	* Implement --rebuild
	* cli: pacman command
	* config: default to not devel
	* post_install
	* packages: unify how to get a MakepkgList
	* makepkg: missing require
	* cli
	* Use SH.log
	* aur_rpc: rework class vs modules layout
	* Global aur cache
	* packages.rb: AurMakepkgCache preserve MakepkgList
	* Package by package install method
	* bug fixes + config.default_packages
	* repos.rb: RepoPkgs, LocalRepo
	* bugfixes + TODO++
	* MakepkgList.from_dir, Repo.foreign_packages
	* verify signatures
	* db.rb: use bsdtar rather than bsdcat to parse db files
	* packages.rb: add keys which have array values
	* Makepkg: edit and edit_pkgbuild
	* db and packages: more bug fixes
	* Bug fixes
	* no_load_config: don't read the user config file
	* Bug fixes + update TODO list
	* Bug fixes
	* makepkg: methods now return success or failure
	* Comments + api change
	* PackageFiles: default to bsdtar rathern than expac
	* More bug fixes
	* Bug fixes and be less verbose
	* makepkg: view before pkgver
	* config: use deep_merge
	* @config.sign: sign files rather than just a file
	* makepkg: done_view and done_build
	* makepkg: move git stuff to its own class
	* devtools + makepkg: unify api
	* sign: uniformise api
	* Rework sudo_loop, put it in shell_helpers
	* packages: chain queries
	* makepkg: get options + db sign files
	* makepkg: check pkgver
	* More bug fixes
	* Bug fixes
	* Bug fixes
	* VirtualMakepkgCache
	* MakepkgList cache
	* packages: to_ext_query
	* aur_rpc: AurQueryCustom to set individual @config
	* Pass along config and allow to specify the default PackageList class
	* packages: fix ups
	* packages: better api for do_install
	* packages: ignore
	* config.rb: sudo_loop, get_config_file
	* config.rb: sudo loop + options
	* Warn when a package was not built
	* packages update/install: do it against another list
	* Inject config
	* Split into different files

== Release v0.1.0 (2018-09-07) ==

	* Update library paths
	* Add code + gemspec dependencies
	* Update README.md
	* Initial commit.

