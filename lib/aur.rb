require 'aur/version'
require 'aur/config'
require 'aur/aur_rpc'
require 'aur/db'
require 'aur/repos'
require 'aur/versions'
require 'aur/devtools'
require 'aur/makepkg'
require 'aur/packages'

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
=end

# TODO:
# - use https://github.com/falconindy/pkgbuild-introspection/ to  speed up .SRCINFO
# - --devel switch?
# - view only when updated/new
# - confirm before installing or updating pkgver (this is somewhat orthogonal to exiting when view return false since we may want to not view the files)
# - more commands for cli
# - tests
# - due to vercmp, we need to reset packages before pulling
# - preference to decide which :provides to choose
