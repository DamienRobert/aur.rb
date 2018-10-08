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
# - read the local db directly
# - --devel switch?
# - aur search cache + global aur cache
# - view only when updated/new
# - confirm before installing or updating pkgver (this is somewhat orthogonal to exiting when view return false since we may want to not view the files)
# - cli
# - tests
# - default package list (think of the case of the user who don't want a db)
# - aur.install only update the db, add a command to also do a local pacman
#   install? (when not building a chroot, we already call sync_db, which will
#   update db pacakges which are already installed, but not new packages =>
#   need to call `tools.sync_db(db.repo_name, install: [self.name])`)
# - configure where to search for missing package (on a case by case basis)
# - due to vercmp, we need to reset packages before pulling
