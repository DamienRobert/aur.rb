require 'aur/version'
require 'aur/config'
require 'aur/aur_rpc'
require 'aur/db'
require 'aur/repos'
require 'aur/versions'
require 'aur/devtools'
require 'aur/makepkg'
require 'aur/packages'
require 'aur/install_packages'

=begin
# query aur
Archlinux::AurQuery.packages("pacaur")

# Make a package
m=Archlinux::Makepkg.new("pacaur")
m.edit
m.makepkg("--geninteg") #update PKGBUILD (todo: add a function for that?)
m.install

# install a package
aur=Archlinux::AurPackageList.new([])
l=aur.install("pacaur")

# check update and new installation compared to a db
aur=Archlinux.config.db.packages
aur=Archlinux.config.default_packages #or get default packages
aur.update?
aur.install?("pacaur", update: true)

# Clean/Change cache:
Archlinux.config.instance_variable_set(:@install_list, nil)
aur.install_list=Archlinux.config.install_list


# Update a db with the latest packages available on the local filesystem
db=Archlinux.config.db
db.check_udpate / db.update
# see package names
db.packages.l.keys

# Check for useless packages in the db
pkgs = Archlinux.config.db.packages
needed = pkgs.rget(*wanted_pkgs)
# present = pkgs.latest.keys ## we want the version
present = pkgs.l.keys
notneeded=present - needed
files=pkgs.slice(*notneeded).map {|k,v| v.file}
db.remove(*files)
=end

=begin
TODO:
- use https://github.com/falconindy/pkgbuild-introspection/ to  speed up .SRCINFO
- view only when updated/new + add trusted PKGBUILD
- confirm before installing or updating pkgver (this is somewhat orthogonal to exiting when view return false since we may want to not view the files)
- tests
- due to vercmp, we need to reset packages before pulling
  => use stash?
- preference to decide which :provides to choose
  (and favorise local packages for provides)
- in `official` we need to also list packages provided by them, eg
libarchive provides libarchive.so (but libarchive.so does not exist
separately, but eg aurutils-git requires it)
- when using AurMakepkgCache, missing packages info are repeated several
times
- replace AurMakepkgCache with a more generic aggregater
- using tsort in rget won't do a breadth first search, which would reduce
the number of aur queries. With tsort packages are queried one by one.
- split Makepkg into a class for downloading/viewing/querying and the
class for installing. This will allow to support both github and the aur
rpc.
- in `sync_db` setup a simily local cache so that the packages don't get
copied twice
- prefetch gpg for signature
- check if splitpackages are handled correctly
- more commands for cli:
  - in db update, allow to be more atomic, same for clear
  - add --no-fetch and --fetch=only; and --extra-db=; and --buildopts="..."
  - add 'package info/compare/list pkgs...'
=end
