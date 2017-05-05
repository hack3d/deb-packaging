#!/bin/bash

# Are we running as root?
if [ "$(id -u)" -ne "0" ] ; then
  echo "error: this script must be executed with root privileges!"
  exit 1
fi

# Check if ./functions.sh script exists
if [ ! -r "../../functions.sh" ] ; then
  echo "error: '../../functions.sh' required script not found!"
  exit 1
fi

# Load utility functions
. ../../functions.sh

# Introdruce settings
set -e
echo -n -e "\n#\n# Bootstrap Settings\n#\n"
set -x

# Config for chroot

if [ "${1}" = "armv7" ] ; then
    APT_SERVER=mirrordirector.raspbian.org
    DISTRIBUTION=raspbian
    RELEASE_ARCH=armhf
    RELEASE=stretch
    QEMU_BINARY=/usr/bin/qemu-arm-static
elif [ "${1}" = "i686" ] ; then
    APT_SERVER=ftp.de.debian.org
    DISTRIBUTION=debian
    RELEASE_ARCH=i386
    RELEASE=stretch
    QEMU_BINARY=/usr/bin/qemu-i386-static
elif [ "${1}" = "amd64" ] ; then
    APT_SERVER=ftp.de.debian.org
    DISTRIBUTION=debian
    RELEASE_ARCH=amd64
    RELEASE=stretch
    QEMU_BINARY=/usr/bin/qemu-x86_64-static
else
    echo -e "The architecture ${1} is not supported"
    exit 1
fi

BASEDIR=$(mktemp -d /tmp/build.XXXXXX)
R="${BASEDIR}/chroot"
WRK="${BASEDIR}/debbuild"
SRC_DIR=/tmp
PKGNAME=$(basename ${PWD})

# Packages required for bootstrapping
REQUIRED_PACKAGES="debootstrap debian-archive-keyring qemu-user-static binfmt-support git"
MISSING_PACKAGES=""

set +x

# Check if all required packages are installed on the build system
for package in $REQUIRED_PACKAGES ; do
  if [ "`dpkg-query -W -f='${Status}' $package`" != "install ok installed" ] ; then
    MISSING_PACKAGES="${MISSING_PACKAGES} $package"
  fi
done

# Ask if missing packages should get installed right now
if [ -n "$MISSING_PACKAGES" ] ; then
  echo "the following packages needed by this script are not installed:"
  echo "$MISSING_PACKAGES"

  echo -n "\ndo you want to install the missing packages right now? [y/n] "
  read confirm
  [ "$confirm" != "y" ] && exit 1
fi

set -x

# Call "cleanup" function on various signals and errors
trap cleanup 0 1 2 3 6

function get_repo_key() {
mkdir -p "${R}"

REPOKEY=""
if [ "$DISTRIBUTION" = raspbian ] ; then
 REPOKEY="build/raspbianrepokey.gpg"
  if [ -f $REPOKEY ] ; then
  rm $REPOKEY
  fi
 wget -O - $APT_SERVER/raspbian.public.key | gpg --no-default-keyring --keyring $REPOKEY --import
 REPOKEY="--keyring ${REPOKEY}"
fi
}

function prepare_build_env() {  

    APT_INCLUDES=apt-transport-https,apt-utils,ca-certificates,dialog,sudo,git,build-essential,bc,dh-systemd,python-virtualenv,python2.7,python2.7-dev,dh-virtualenv,python3-venv,python3-dev,python3

    # Base debootstrap
    if [ "${1}" = "armv7" ] ; then
        APT_INCLUDES="${APT_INCLUDES},raspbian-archive-keyring"
        http_proxy=${APT_PROXY} debootstrap --arch="${RELEASE_ARCH}" $REPOKEY --foreign --include="${APT_INCLUDES}" "${RELEASE}" "${R}" "http://${APT_SERVER}/${DISTRIBUTION}"
    else
        http_proxy=${APT_PROXY} debootstrap --arch="${RELEASE_ARCH}" --foreign --include="${APT_INCLUDES}" "${RELEASE}" "${R}" "http://${APT_SERVER}/${DISTRIBUTION}"
    fi
    
    # Copy qemu emulator binary to chroot
    cp "${QEMU_BINARY}" "$R/usr/bin"

    # Copy debian-archive-keyring.pgp
    mkdir -p "$R/usr/share/keyrings"
    install_readonly /usr/share/keyrings/debian-archive-keyring.gpg "${R}/usr/share/keyrings/debian-archive-keyring.gpg"
    
    # Complete the bootstrapping process
    chroot_exec /debootstrap/debootstrap --second-stage
    
    # Mount required filesystems
    mount -t proc none "$R/proc"
    mount -t sysfs none "$R/sys"
    
    # Mount pseudo terminal slave if supported by Debian release
    #if [ -d "${R}/dev/pts" ] ; then
        mount --bind /dev/pts "${R}/dev/pts"
    #fi
}


function uri_parser() {
    # uri capture
    uri="$@"
    # safe escaping
    uri="${uri//\`/%60}"
    uri="${uri//\"/%22}"
    # top level parsing
    pattern='^(([a-z]{3,5})://)?((([^:\/]+)(:([^@\/]*))?@)?([^:\/?]+)(:([0-9]+))?)(\/[^?]*)?(\?[^#]*)?(#.*)?$'
    [[ "$uri" =~ $pattern ]] || return 1;
    # component extraction
    uri=${BASH_REMATCH[0]}
    uri_schema=${BASH_REMATCH[2]}
    uri_address=${BASH_REMATCH[3]}
    uri_user=${BASH_REMATCH[5]}
    uri_password=${BASH_REMATCH[7]}
    uri_host=${BASH_REMATCH[8]}
    uri_port=${BASH_REMATCH[10]}
    uri_path=${BASH_REMATCH[11]}
    uri_query=${BASH_REMATCH[12]}
    uri_fragment=${BASH_REMATCH[13]}
    # path parsing
    count=0
    path="$uri_path"
    pattern='^/+([^/]+)'
    while [[ $path =~ $pattern ]]; do
        eval "uri_parts[$count]=\"${BASH_REMATCH[1]}\""
        path="${path:${#BASH_REMATCH[0]}}"
        ((count++))
    done
    # query parsing
    count=0
    query="$uri_query"
    pattern='^[?&]+([^= ]+)(=([^&]*))?'
    while [[ $query =~ $pattern ]]; do
        eval "uri_args[$count]=\"${BASH_REMATCH[1]}\""
        eval "uri_arg_${BASH_REMATCH[1]}=\"${BASH_REMATCH[3]}\""
        query="${query:${#BASH_REMATCH[0]}}"
        ((count++))
    done
    # return success
    return 0
}

#########
## MAIN 
#########
echo -e "Prepare environment"
rm -rf "${WRK}"
mkdir -p "${WRK}"

if [ ! -f sources ]; then
  echo "No sources file available in this directory."
  exit 1
fi

get_repo_key
prepare_build_env "${1}"

# print architecutre
chroot_exec dpkg --print-architecture

chroot_exec mkdir -p ${SRC_DIR}/${PKGNAME}

while read -r src filename dest taropt || [[ -n "$src" ]]; do
	if [[ "$src" =~ ^# ]]; then
		continue
  	fi

	TAROPT=''
	if [ "${taropt}" == 'strip1' ]; then
		TAROPT="--strip-components 1"
	fi

	if [ "${dest}" == '-' ]; then
		dest=''
	fi

	if [ -z "$filename" ]; then
		filename=$(basename $src)
	fi

	if [[ "$src" =~ ^http ]] || [[ "$src" =~ ^ftp ]]; then
		unset WGET_OPT
		#uri_parser ${src}
		if [ -r .token ]; then
			TOKEN=$(cat .token)
			if [ "${uri_host}" == *'github.com' ]; then
				echo "GitHub tokens are not supported yet!"
			elif [ "${uri_host}" == *'gitlab'* ]; then
				WGET_OPT="--header=\'PRIVATE-TOKEN: ${TOKEN}\'"
			else
				echo "Unsupported"
			fi
		fi
		wget --no-check-certificate "$src" ${WGET_OPT} -O "${WRK}/${filename}"
	else
    		cp -a "$src" "${WRK}/${filename}"
  	fi
	tar xf "$WRK/${filename}" -C "${R}${SRC_DIR}/${PKGNAME}/${dest}" ${TAROPT}
    cp "${WRK}/${filename}" "${R}${SRC_DIR}"

done <sources

cp -a "$(pwd)/debian" "${R}${SRC_DIR}/${PKGNAME}"

# create virtual python enviroment
if [ "${PKGNAME}" == "stockanalyses-downloader" ] ; then
	chroot_exec python3.5 -m venv "${SRC_DIR}/virt-build"
fi

if [ "${PKGNAME}" == "stockanalyses-importer" ] ; then
	chroot_exec python3.5 -m venv "${SRC_DIR}/virt-build"
fi

chroot_exec

cp $(ls ${R}${SRC_DIR}/*.deb) "${SRC_DIR}"

echo -e "Cleaning up"
cleanup
rm -rf "${BASEDIR}"
