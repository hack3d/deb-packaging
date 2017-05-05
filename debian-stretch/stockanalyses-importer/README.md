The following commands has to be run by hand in the chroot:
 * pushd /tmp && source virt-build/bin/activate
 * pushd /tmp/stockanalyses-importer && dpkg-buildpackage -us -uc
