#!/bin/sh

# simple appimage sandbox
# sandbox appimages and appimage like formats easily
# can also sandbox standalone binaries and similar

# THIS PRODUCT COMES WITH NO WARRANTY!

set -e

if [ "$SAS_DEBUG" = 1 ]; then
	set -x
fi

VERSION=1.7

ADD_DIR=""
ALLOW_XDG_OPEN=1
ALLOW_FUSE=0
ALLOW_BINDIR=0
ALLOW_DATADIR=0
ALLOW_CONFIGDIR=0
ALLOW_CACHEDIR=0
ALLOW_STATEDIR=0
ALLOW_RUNDIR=0
ALLOW_APPLICATIONSDIR=0
ALLOW_DESKTOPDIR=0
ALLOW_DOCUMENTSDIR=0
ALLOW_DOWNLOADDIR=0
ALLOW_GAMESDIR=0
ALLOW_MUSICDIR=0
ALLOW_PICTURESDIR=0
ALLOW_PUBLICSHAREDIR=0
ALLOW_TEMPLATESDIR=0
ALLOW_VIDEOSDIR=0

BWRAPCMD="bwrap"

SHARE_APP_CONFIG=1
SHARE_APP_THEME=1
SHARE_APP_NETWORK=1
SHARE_APP_AUDIO=1
SHARE_APP_DBUS=1
SHARE_APP_XDISPLAY=1
SHARE_APP_WDISPLAY=1
SHARE_APP_PIPEWIRE=1
SHARE_APP_TMPDIR=1

SHARE_DEV_DRI=1
SHARE_DEV_INPUT=1
SHARE_DEV_ALL=1

SAS_PRELOAD="${SAS_PRELOAD:-0}"
SAS_CURRENTDIR="$(cd "${0%/*}" && echo "$PWD")"
SAS_XDG_OPEN_DAEMON=""
SAS_XDG_OPEN_DAEMON_PID=""

IS_APPIMAGE=0
IS_TRUSTED_ONCE=0
APP_TMPDIR=""
TARGET=""
MOUNT_POINT=""
FAKEHOME=""

mountcheck=""
xdgcheck=""

DEPENDENCIES="
	awk
	bwrap
	dwarfs
	grep
	head
	cksum
	od
	readlink
	squashfuse
	tail
	umount
"

# Name of variables and files to be checked
XDG_BASE_DIRS="BINDIR CACHEDIR CONFIGDIR DATADIR RUNDIR STATEDIR"
XDG_USER_DIRS="APPLICATIONSDIR DESKTOPDIR DOCUMENTSDIR
	DOWNLOADDIR GAMESDIR MUSICDIR PICTURESDIR
	PUBLICSHAREDIR TEMPLATESDIR VIDEOSDIR
"

DEFAULT_SYS_DIRS="
	/bin
	/etc
	/lib
	/lib32
	/lib64
	/opt
	/sbin
	/usr/bin
	/usr/lib
	/usr/lib32
	/usr/lib64
	/usr/local
	/usr/sbin
	/usr/share
"

_cleanup() {
	set +u
	if [ "$IS_TRUSTED_ONCE" = 1 ]; then
		chmod -x "$TARGET" || true
	fi
	if [ "$SAS_PRELOAD" != 1 ] && [ -n "$MOUNT_POINT" ]; then
		umount "$MOUNT_POINT"
		rm -rf "$MOUNT_POINT"
	fi
	if [ -n "$APP_TMPDIR" ]; then
		rm -rf "$APP_TMPDIR"
	fi
	if [ -n "$SAS_XDG_OPEN_DAEMON_PID" ]; then
		kill "$SAS_XDG_OPEN_DAEMON_PID" 2>/dev/null || true
	fi
	if [ -f "$RUNDIR"/sas-xdg-open-daemon.lock ]; then
		rm -f "$RUNDIR"/sas-xdg-open-daemon.lock
	fi
}

trap _cleanup INT TERM EXIT

_help() {
	printf '\n%s\n\n' "   USAGE: $0 [OPTIONS] /path/to/app"
	exit 1
}

_error() {
	>&2 printf '\n%s\n\n' "   💀 ERROR: $*"
	exit 1
}

_dep_check() {
	for d do
		command -v "$d" 1>/dev/null || _error "Missing dependency $d"
	done
}

# get home or id directly from /etc/passwd, replaces id and getent
_get_sys_info() {
	case "$1" in
		home) i=6   ;;
		id)   i=3   ;;
		gid)  i=4   ;;
		''|*) exit 1;;
	esac
	awk -F':' -v U="$USER" -v F="$i" '$1==U {print $F; exit}' /etc/passwd
}

# use shell builtins for dirname and basename, saves a wooping 500us lol
# from https://github.com/dylanaraps/pure-sh-bible
dirname() {
	[ -n "$1" ] || return 1
	dir="$1"
	dir=${dir%%"${dir##*[!/]}"}
	if [ "${dir##*/*}" ]; then
		dir=.
	fi
	dir=${dir%/*}
	dir=${dir%%"${dir##*[!/]}"}
	printf '%s\n' "${dir:-/}"
}

basename() {
	[ -n "$1" ] || return 1
	dir=${1%${1##*[!/]}}
	dir=${dir##*/}
	dir=${dir%"$2"}
	printf '%s\n' "${dir:-/}"
}

# try to use shell builtins to resolve symlinks
# else fallback to readlink, this saves +4ms
_readlink() {
	if [ "$1" = '-f' ] && cd "$2" 2>/dev/null; then
		echo "$PWD"
	else
		command readlink "$@"
	fi
}

# POSIX shell doesn't support arrays we use awk to save it into a variable
# then with 'eval set -- $var' we add it to the positional array
# see https://unix.stackexchange.com/questions/421158/how-to-use-pseudo-arrays-in-posix-shell-script
_save_array() {
	LC_ALL=C awk -v q="'" '
	BEGIN{
		for (i=1; i<ARGC; i++) {
			gsub(q, q "\\" q q, ARGV[i])
			printf "%s ", q ARGV[i] q
		}
		print ""
	}' "$@"
}

_is_target() {
	app_path="$(command -v "$1" 2>/dev/null)"
	TARGET="$(readlink -f "${app_path:-$1}")"
	if [ -f "$TARGET" ]; then
		APPNAME="$(basename "$TARGET")"
		APP_APPIMAGE="$TARGET"
		APP_ARGV0="$1"
	else
		return 1
	fi
}

_is_spooky() {
	to_check="$1"
	if [ -L "$to_check" ]; then
		to_check="$(_readlink -f "$to_check")"
	fi

	case "$to_check" in
		""           |\
		"/"          |\
		*//*         |\
		*./*         |\
		*..*         |\
		"/home"      |\
		"/var/home"  |\
		"$HOME"      |\
		"/run"       |\
		"/dev"       |\
		"/proc"      |\
		"/mnt"       |\
		"/media"     |\
		*.local      |\
		*.firefox    |\
		*.firedragon |\
		*.librewolf  |\
		*.mullvad*   |\
		*.zen        |\
		*.gnupg      |\
		*.thunderbird|\
		*.mozilla    |\
		*.ssh        |\
		*.vim*       |\
		*.profile    |\
		*.bash*      |\
		*.zsh*       |\
		*fish        |\
		"$ZDOTDIR"   )
			return 1
			;;
		/*)  # make sure valid paths start with /
			return 0
			;;
		*)
			return 1
			;;
	esac
}

_is_appimage() {
	# do not check if in nested sandbox or allowing fuse
	if [ "$SAS_SANDBOX" = 1 ] || [ "$ALLOW_FUSE" = 1 ]; then
		return 1
	fi

	case "$(head -c 10 "$1")" in
		*ELF*AI|\
		*ELF*RI|\
		*ELF*AB) IS_APPIMAGE=1;;
		''|*)    return 1     ;;
	esac 2>/dev/null
}

_check_xdgbase() {
	for d do
		eval "d=\$$d"
		if ! _is_spooky "$d"; then
			return 1
		fi
	done
}

# safe and much much faster method to get user dirs using shell builtins
# https://github.com/dylanaraps/pure-sh-bible?tab=readme-ov-file#files
_check_userdirs() {
	if [ ! -f "$CONFIGDIR/user-dirs.dirs" ]; then
		return 1
	fi
	while IFS='=' read -r key val; do
		# Skip commented lines
		[ "${key##\#*}" ] || continue
		# check weird stuff before running eval
		case "$val" in
			''|*['('')''`'';']*) continue;;
			*) dir="$(eval echo "$val")" ;;
		esac
		# declare each variable to each XDG dir
		case "$key" in
			XDG_APPLICATIONS_DIR) XDG_APPLICATIONS_DIR="$dir";;
			XDG_DESKTOP_DIR)      XDG_DESKTOP_DIR="$dir"     ;;
			XDG_DOCUMENTS_DIR)    XDG_DOCUMENTS_DIR="$dir"   ;;
			XDG_DOWNLOAD_DIR)     XDG_DOWNLOAD_DIR="$dir"    ;;
			XDG_GAMES_DIR)        XDG_GAMES_DIR="$dir"       ;;
			XDG_MUSIC_DIR)        XDG_MUSIC_DIR="$dir"       ;;
			XDG_PICTURES_DIR)     XDG_PICTURES_DIR="$dir"    ;;
			XDG_PUBLICSHARE_DIR)  XDG_PUBLICSHARE_DIR="$dir" ;;
			XDG_TEMPLATES_DIR)    XDG_TEMPLATES_DIR="$dir"   ;;
			XDG_VIDEOS_DIR)       XDG_VIDEOS_DIR="$dir"      ;;
		esac
	done < "$CONFIGDIR/user-dirs.dirs"
}

_make_fakehome() {
	if [ -d "$FAKEHOME" ]; then
		return 0
	elif [ -n "$1" ]; then
		FAKEHOME="$(_readlink -f "$1")"
	else
		FAKEHOME="$(dirname "$TARGET")/$APPNAME.home"
	fi

	mkdir -p "$FAKEHOME"/.app 2>/dev/null || true

	if ! _is_spooky "$FAKEHOME"; then
		_error "Cannot use $1 as sandboxed home"
	elif [ ! -w "$FAKEHOME" ]; then
		_error "Cannot make sandboxed home at $FAKEHOME"
	fi
}

_make_xdg_open_daemon() {
	SAS_XDG_OPEN_DAEMON="$RUNDIR"/sas-xdg-open-daemon

	pipe="$RUNDIR"/sas-xdg-open-pipe
	xdgopen="$RUNDIR"/sas-xdg-open

	if [ ! -p "$pipe" ]; then
		mkfifo "$pipe"
	fi

	if [ ! -x "$xdgopen" ]; then
		cat <<-'EOF' > "$xdgopen"
		#!/bin/sh
		p=$XDG_RUNTIME_DIR/sas-xdg-open-pipe
		[ -p "$p" ] && echo "$@" >> "$p" && exit 0
		exit 1
		EOF
		chmod +x "$xdgopen"
	fi

	if [ ! -x "$SAS_XDG_OPEN_DAEMON" ]; then
		cat <<-EOF > "$SAS_XDG_OPEN_DAEMON"
		#!/bin/sh
		lockfile="$RUNDIR"/sas-xdg-open-daemon.lock
		_remove_lockfile() { rm -f "\$lockfile"; }
		if [ ! -f "\$lockfile" ]; then
		    trap _remove_lockfile INT TERM EXIT
		    :> "\$lockfile"
		    while :; do
		        read -r CMD < "$pipe"
		        if [ -n "\$CMD" ]; then
		            xdg-open "\$CMD"
		        fi
		    done
		fi
		EOF
		chmod +x "$SAS_XDG_OPEN_DAEMON"
	fi
}

_get_hash() {
	HASH="$(tail -vc 1048576 "$1" | cksum)"
	HASH="${HASH%% *}"
	if [ -z "$HASH" ]; then
		_error "Something went wrong getting hash from $1"
	fi
}

_find_offset() {
	offset="$(LC_ALL=C od -An -vtx1 -N 64 -- "$1" | awk '
	  BEGIN {
		for (i = 0; i < 16; i++) {
			c = sprintf("%x", i)
			H[c] = i
			H[toupper(c)] = i
		}
	  }
	  {
		  elfHeader = elfHeader " " $0
	  }
	  END {
		$0 = toupper(elfHeader)
		if ($5 == "02") is64 = 1; else is64 = 0
		if ($6 == "02") isBE = 1; else isBE = 0
		if (is64) {
			if (isBE) {
				shoff = $41 $42 $43 $44 $45 $46 $47 $48
				shentsize = $59 $60
				shnum = $61 $62
			} else {
				shoff = $48 $47 $46 $45 $44 $43 $42 $41
				shentsize = $60 $59
				shnum = $62 $61
			}
		  } else {
			if (isBE) {
				shoff = $33 $34 $35 $36
				shentsize = $47 $48
				shnum = $49 $50
			} else {
				shoff = $36 $35 $34 $33
				shentsize = $48 $47
				shnum = $50 $49
			}
		  }
		  print parsehex(shoff) + parsehex(shentsize) * parsehex(shnum)
		}
	  function parsehex(v,    i, r) {
		  r = 0
		  for (i = 1; i <= length(v); i++)
		  r = r * 16 + H[substr(v, i, 1)]
		  return r
	  }'
	)"
	if [ -z "$offset" ]; then
		return 1
	fi
}

_make_mountpoint() {
	MOUNT_POINT="$TMPDIR/.sas-mount-$USER/$APPNAME-$HASH"
	>&2 printf '%s\n' "$MOUNT_POINT"
	if [ -f "$MOUNT_POINT"/AppRun ] || [ -f "$MOUNT_POINT"/Run ]; then
		return 0 # it is mounted already
	else
		mkdir -p "$MOUNT_POINT"
	fi

	# common flags for squashfuse and dwarfs
	set -- \
	  -o ro,nodev,uid="$ID",gid="$GID" \
	  -o offset="$offset" "$TARGET" "$MOUNT_POINT"
	( squashfuse "$@" 2>/dev/null || dwarfs "$@" ) &
	mountcheck=$!
}

_make_bwrap_array() {
	set -u
	set -- \
	  --dir /app                          \
	  --perms 0700                        \
	  --dir /run/user/"$ID"               \
	  --bind "$FAKEHOME" "$HOME"          \
	  --bind "$FAKEHOME"/.app /app        \
	  --ro-bind "$TARGET" /app/"$APPNAME" \
	  --proc /proc                        \
	  --unshare-user-try                  \
	  --unshare-pid                       \
	  --unshare-uts                       \
	  --die-with-parent                   \
	  --unshare-cgroup-try                \
	  --new-session                       \
	  --unshare-ipc                       \
	  --setenv SAS_SANDBOX 1              \
	  --setenv  TMPDIR  /tmp              \
	  --setenv  HOME    "$HOME"           \
	  --setenv XDG_RUNTIME_DIR  /run/user/"$ID"

	if [ "$ALLOW_FUSE" = 1 ]; then
		# CAP_SYS_ADMIN needed when allowing FUSE inside sandbox
		set -- "$@" --cap-add CAP_SYS_ADMIN
	else
		# lets appimages run inside container without FUSE
		set -- "$@" --setenv APPIMAGE_EXTRACT_AND_RUN 1
	fi

	for d in $DEFAULT_SYS_DIRS; do
		if [ -d "$d" ]; then
			set -- "$@" --ro-bind-try "$d" "$d"
		fi
	done

	if [ "$SHARE_DEV_ALL" = 1 ]; then
		SHARE_DEV_DRI=1
		SHARE_DEV_INPUT=1
		set -- "$@" \
		  --dev-bind-try /dev       /dev \
		  --ro-bind-try  /sys/class /sys/class
	else
		set -- "$@" --dev /dev
	fi
	if [ "$SHARE_DEV_DRI" = 1 ]; then
		set -- "$@" \
		  --ro-bind-try  /usr/share/glvnd        /usr/share/glvnd     \
		  --ro-bind-try  /usr/share/vulkan       /usr/share/vulkan    \
		  --ro-bind-try  /sys/dev/char           /sys/dev/char        \
		  --dev-bind-try /dev/nvidiactl          /dev/nvidiactl       \
		  --dev-bind-try /dev/nvidia0            /dev/nvidia0         \
		  --dev-bind-try /dev/nvidia-modeset     /dev/nvidia-modeset  \
		  --ro-bind-try  /sys/devices/pci0000:00 /sys/devices/pci0000:00
	fi
	if [ "$SHARE_DEV_INPUT" = 1 ]; then
		set -- "$@" --ro-bind  /sys/class/input  /sys/class/input
	fi

	if [ "$IS_APPIMAGE" = 1 ]; then
		set -- "$@" \
		  --bind-try "$MOUNT_POINT" "$MOUNT_POINT" \
		  --setenv APPIMAGE  "$APP_APPIMAGE"       \
		  --setenv APPDIR    "$MOUNT_POINT"        \
		  --setenv ARGV0     "$APP_ARGV0"
	fi
	if [ "$SHARE_APP_TMPDIR" = 1 ]; then
		set -- "$@" --bind-try /tmp /tmp
	else
		APP_TMPDIR="$TMPDIR/.sas-tmpdir-$USER/$APPNAME-$HASH"
		mkdir -p "$APP_TMPDIR"
		>&2 printf '%s\n' "$APP_TMPDIR"
		set -- "$@" --bind-try /tmp "$APP_TMPDIR"
	fi
	if [ "$SHARE_APP_DBUS" = 1 ]; then
		set -- "$@" \
		  --ro-bind-try /var/lib/dbus  /var/lib/dbus  \
		  --ro-bind-try "$RUNDIR"/bus  /run/user/"$ID"/bus
	fi
	if [ "$SHARE_APP_AUDIO" = 1 ]; then
		set -- "$@" \
		  --dev-bind-try /dev/snd       /dev/snd \
		  --ro-bind-try "$RUNDIR"/pulse /run/user/"$ID"/pulse
	fi
	if [ "$SHARE_APP_PIPEWIRE" = 1 ]; then
		set -- "$@" \
		  --ro-bind-try "$RUNDIR"/pipewire-0 /run/user/"$ID"/pipewire-0
	fi
	if [ "$SHARE_APP_XDISPLAY" = 1 ]; then
		set -- "$@" \
		  --setenv XAUTHORITY "$HOME"/.Xauthority     \
		  --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix \
		  --ro-bind-try "$XDISPLAY" "$HOME"/.Xauthority
	fi
	if [ "$SHARE_APP_WDISPLAY" = 1 ]; then
		set -- "$@" \
		  --setenv WAYLAND_DISPLAY wayland-0 \
		  --ro-bind-try "$RUNDIR"/"$WDISPLAY" /run/user/"$ID"/wayland-0
	fi
	if [ "$SHARE_APP_NETWORK" = 1 ]; then
		set -- "$@" \
		  --share-net \
		  --ro-bind-try /run/systemd/resolve /run/systemd/resolve
	else
		set -- "$@" --unshare-net
	fi
	if [ "$SHARE_APP_THEME" = 1 ]; then
		while read -r d; do
			if [ -e "$d" ]; then
				set -- "$@" --ro-bind-try "$d" "$d"
			fi
		done <<-EOF
		$THEME_DIRS
		EOF
	fi
	if [ "$SHARE_APP_CONFIG" = 1 ]; then
		set -- "$@" \
		  --bind-try "$DATADIR"/"$APPNAME"   "$DATADIR"/"$APPNAME"  \
		  --bind-try "$CACHEDIR"/"$APPNAME"  "$CACHEDIR"/"$APPNAME" \
		  --bind-try "$CONFIGDIR"/"$APPNAME" "$CONFIGDIR"/"$APPNAME"
	fi
	if [ "$ALLOW_XDG_OPEN" = 1 ]; then
		_make_xdg_open_daemon
		set -- "$@" \
			--ro-bind-try "$xdgopen" /bin/xdg-open     \
			--ro-bind-try "$xdgopen" /usr/bin/xdg-open \
			--ro-bind-try "$pipe"    /run/user/"$ID"/"${pipe##*/}"
	fi

	for d in $XDG_USER_DIRS $XDG_BASE_DIRS; do
		ALLOW_VAR="ALLOW_$d"
		eval "ALLOW_VAR=\$$ALLOW_VAR"
		eval "d=\$$d"
		case "$ALLOW_VAR" in
			1) set -- "$@" --ro-bind-try "$d" "$d";;
			2) set -- "$@" --bind-try    "$d" "$d";;
		esac
	done

	while read -r d; do
		case "$d" in
			""|:*);; # do nothing
			*:rw) set -- "$@" --bind-try    "${d%%:*}" "${d%%:*}";;
			*)    set -- "$@" --ro-bind-try "${d%%:*}" "${d%%:*}";;
		esac
	done <<-EOF
	$ADD_DIR
	EOF

	BWRAP_ARRAY=$(_save_array "$@")
	set +u
}

_extract_only() {
	mkdir -p "$PWD"/AppDir
	cp -r "$MOUNT_POINT"/${1:-*} "$PWD"/AppDir
	if [ ! -d "$PWD"/squashfs-root ]; then
		ln -s "$PWD"/AppDir "$PWD"/squashfs-root
	fi
}

# check if running as appimage
if [ -d "$SAS_CURRENTDIR"/bin ]; then
	PATH="$SAS_CURRENTDIR/bin:$PATH"
fi

# check dependencies
_dep_check $DEPENDENCIES

# Make sure we always have the real home
USER="${LOGNAME:-${USER:-${USERNAME}}}"
if [ -f '/etc/passwd' ]; then
	SAS_HOME="$(_get_sys_info home)"
	SAS_ID="$(_get_sys_info id)"
	SAS_GID="$(_get_sys_info gid)"
	# export internal variables this way apps with
	# restricted access to /etc can still use this
	export SAS_HOME SAS_ID SAS_GID
fi

HOME="$SAS_HOME"
ID="$SAS_ID"
GID="$SAS_GID"

if [ -z "$USER" ] || [ ! -d "$HOME" ] || [ -z "$ID" ] || [ -z "$GID" ]; then
	_error "This system is fucked up"
fi

# check if namespaces are disabled
if [ -f "$SAS_CURRENTDIR"/detect-nonsense.sh ]; then
	"$SAS_CURRENTDIR"/detect-nonsense.sh || true
fi

# get xdg vars
BINDIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATADIR="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIGDIR="${XDG_CONFIG_HOME:-$HOME/.config}"
CACHEDIR="${XDG_CACHE_HOME:-$HOME/.cache}"
STATEDIR="${XDG_STATE_HOME:-$HOME/.local/state}"
RUNDIR="${XDG_RUNTIME_DIR:-/run/user/$ID}"

# check xdg user dirs
_check_userdirs || true

APPLICATIONSDIR="${XDG_APPLICATIONS_DIR:-$HOME/Applications}"
DESKTOPDIR="${XDG_DESKTOP_DIR:-$HOME/Desktop}"
DOCUMENTSDIR="${XDG_DOCUMENTS_DIR:-$HOME/Documents}"
DOWNLOADDIR="${XDG_DOWNLOAD_DIR:-$HOME/Downloads}"
GAMESDIR="${XDG_GAMES_DIR:-$HOME/Games}"
MUSICDIR="${XDG_MUSIC_DIR:-$HOME/Music}"
PICTURESDIR="${XDG_PICTURES_DIR:-$HOME/Pictures}"
PUBLICSHAREDIR="${XDG_PUBLICSHARE_DIR:-$HOME/Public}"
TEMPLATESDIR="${XDG_TEMPLATES_DIR:-$HOME/Templates}"
VIDEOSDIR="${XDG_VIDEOS_DIR:-$HOME/Videos}"

ZDOTDIR="$(_readlink -f "${ZDOTDIR:-$HOME}")"
TMPDIR="${TMPDIR:-/tmp}"
WDISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
XDISPLAY="${XAUTHORITY:-$RUNDIR/Xauthority}"

# Default dirs to give read access for working theming
THEME_DIRS="
	$CONFIGDIR/dconf
	$CONFIGDIR/fontconfig
	$CONFIGDIR/gtk-3.0
	$CONFIGDIR/gtk3.0
	$CONFIGDIR/gtk-4.0
	$CONFIGDIR/gtk4.0
	$CONFIGDIR/kdeglobals
	$CONFIGDIR/Kvantum
	$CONFIGDIR/lxde
	$CONFIGDIR/qt5ct
	$CONFIGDIR/qt6ct
	$DATADIR/icons
	$DATADIR/themes
	$DATADIR/fonts
"

# do not share X11 by default on wayland
if [ -S "$RUNDIR"/"$WDISPLAY" ]; then
	SHARE_APP_XDISPLAY=0
fi

# parse the array
while :; do
	case "$1" in
		''|--help|-h|-H)
			_help
			;;
		--version|-v|-V)
			echo "$VERSION"
			exit 0
			;;
		--no-theme)
			SHARE_APP_THEME=0
			shift
			;;
		--no-config)
			SHARE_APP_CONFIG=0
			shift
			;;
		--no-tmpdir)
			SHARE_APP_TMPDIR=0
			shift
			;;
		--no-xdgopen)
			ALLOW_XDG_OPEN=0
			shift
			;;
		--allow-fuse)
			ALLOW_FUSE=1
			shift
			;;
		--allow-nested-caps)
			if command -v bwrap.patched 1>/dev/null; then
				BWRAPCMD="bwrap.patched"
			else
				_error "Missing patched bwrap needed for $1"
			fi
			shift
			;;
		--keep-mount|--preload)
			SAS_PRELOAD=1
			shift
			;;
		--data-dir|--sandboxed-home)
			case "$2" in
				''|-*) _error "No directory given to $1";;
				*)     _make_fakehome "$2"              ;;
			esac
			shift
			shift
			;;
		--add-file|--add-dir)
			case "$2" in
				xdg-applications:rw) ALLOW_APPLICATIONSDIR=2;;
				xdg-applications*)   ALLOW_APPLICATIONSDIR=1;;
				xdg-desktop:rw)      ALLOW_DESKTOPDIR=2     ;;
				xdg-desktop*)        ALLOW_DESKTOPDIR=1     ;;
				xdg-documents:rw)    ALLOW_DOCUMENTSDIR=2   ;;
				xdg-documents*)      ALLOW_DOCUMENTSDIR=1   ;;
				xdg-download:rw)     ALLOW_DOWNLOADDIR=2    ;;
				xdg-download*)       ALLOW_DOWNLOADDIR=1    ;;
				xdg-games:rw)        ALLOW_GAMESDIR=2       ;;
				xdg-games*)          ALLOW_GAMESDIR=1       ;;
				xdg-music:rw)        ALLOW_MUSICDIR=2       ;;
				xdg-music*)          ALLOW_MUSICDIR=1       ;;
				xdg-pictures:rw)     ALLOW_PICTURESDIR=2    ;;
				xdg-pictures*)       ALLOW_PICTURESDIR=1    ;;
				xdg-publicshare:rw)  ALLOW_PUBLICSHAREDIR=2 ;;
				xdg-publicshare*)    ALLOW_PUBLICSHAREDIR=1 ;;
				xdg-templates:rw)    ALLOW_TEMPLATESDIR=2   ;;
				xdg-templates*)      ALLOW_TEMPLATESDIR=1   ;;
				xdg-videos:rw)       ALLOW_VIDEOSDIR=2      ;;
				xdg-videos*)         ALLOW_VIDEOSDIR=1      ;;
				xdg-bin:rw)          ALLOW_BINDIR=2         ;;
				xdg-bin*)            ALLOW_BINDIR=1         ;;
				xdg-cache:rw)        ALLOW_CACHEDIR=2       ;;
				xdg-cache*)          ALLOW_CACHEDIR=1       ;;
				xdg-config:rw)       ALLOW_CONFIGDIR=2      ;;
				xdg-config*)         ALLOW_CONFIGDIR=1      ;;
				xdg-data:rw)         ALLOW_DATADIR=2        ;;
				xdg-data*)           ALLOW_DATADIR=1        ;;
				xdg-rundir:rw)       ALLOW_RUNDIR=2         ;;
				xdg-rundir*)         ALLOW_RUNDIR=1         ;;
				xdg-statedir:rw)     ALLOW_STATEDIR=2       ;;
				xdg-statedir*)       ALLOW_STATEDIR=1       ;;
				''|-*)
					_error "No file/directory given to $1"
					;;
				# Store each extra file/dir in a new line
				# new POSIX doesn't allow newline characters
				# in filenames, which is very useful here
				*)
					ADD_DIR="$ADD_DIR
					$(_readlink -f "$2" || echo "")"
					;;
			esac
			shift
			shift
			;;
		--add-device)
			case "$2" in
				all)   SHARE_DEV_ALL=1               ;;
				dri)   SHARE_DEV_DRI=1               ;;
				input) SHARE_DEV_INPUT=1             ;;
				''|*) _error "$1 Unknown device '$2'";;
			esac
			shift
			shift
			;;
		--rm-device)
			case "$2" in
				all)   SHARE_DEV_ALL=0               ;;
				dri)   SHARE_DEV_DRI=0               ;;
				input) SHARE_DEV_INPUT=0             ;;
				''|*) _error "$1 Unknown device '$2'";;
			esac
			shift
			shift
			;;
		--add-socket)
			case "$2" in
				alsa |\
				audio|\
				pulseaudio) SHARE_APP_AUDIO=1        ;;
				pipewire)   SHARE_APP_PIPEWIRE=1     ;;
				dbus)       SHARE_APP_DBUS=1         ;;
				network)    SHARE_APP_NETWORK=1      ;;
				x11)        SHARE_APP_XDISPLAY=1     ;;
				wayland)    SHARE_APP_WDISPLAY=1     ;;
				''|*) _error "$1 Unknown socket '$2'";;
			esac
			shift
			shift
			;;
		--rm-socket)
			case "$2" in
				alsa |\
				audio|\
				pulseaudio) SHARE_APP_AUDIO=0        ;;
				pipewire)   SHARE_APP_PIPEWIRE=0     ;;
				dbus)       SHARE_APP_DBUS=0         ;;
				network)    SHARE_APP_NETWORK=0      ;;
				x11)        SHARE_APP_XDISPLAY=0     ;;
				wayland)    SHARE_APP_WDISPLAY=0     ;;
				''|*) _error "$1 Unknown socket '$2'";;
			esac
			shift
			shift
			;;
		--rm-file|--rm-dir)
			case "$2" in
				''|-*) _error "No file/directory given to $1";;
				/tmp)  SHARE_APP_TMPDIR=0                    ;;
				*)
					DEFAULT_SYS_DIRS="$(echo \
					  "$DEFAULT_SYS_DIRS" | grep -Fvw "$2"
					)"
					;;
			esac
			shift
			shift
			;;
		--level) # aisap compat
			if [ "$2" != 1 ]; then
				_error "$0 only supports and defaults to $1 1"
			fi
			shift
			shift
			;;
		--trust-once)
			IS_TRUSTED_ONCE=1
			shift
			;;
		--)
			shift
			;;
		-*)
			_error "Unknown option: $1"
			;;
		*)
			if _is_target "$1"; then
				# We shift and break here to later pass
				# the rest of the array to $TO_EXEC
				shift
			else
				_error "Cannot find application to sandbox"
			fi
			break
			;;
	esac
done

# get hash and prepare sandboxed home
_get_hash "$TARGET"

# check if we only want to extract files from app
if [ "$1" = --appimage-extract ]; then
	shift
	>&2 printf '%s\n' "   Extracting '$TARGET'..."
	_is_appimage "$TARGET"
	_find_offset "$TARGET"
	_make_mountpoint "$TARGET"
	wait
	_extract_only "$@"
	>&2 printf '%s\n' "   Suscesfully extracted to '$PWD/AppDir'"
	exit 0
fi

_make_fakehome

# check if any of the xdg vars are spooky
_check_xdgbase $XDG_BASE_DIRS $XDG_USER_DIRS &
xdgcheck=$!

# Check if the app is an appimage, if so mount
if _is_appimage "$TARGET"; then
	_find_offset "$TARGET"
	_make_mountpoint "$TARGET"
fi

# make bwrap array
_make_bwrap_array

if ! wait $xdgcheck; then
	_error "Something is fishy here, bailing out..."
elif ! wait $mountcheck; then
	_error "Something went wrong trying to mount the filesystem..."
fi

if [ "$IS_APPIMAGE" = 1 ]; then
	if [ -f "$MOUNT_POINT"/AppRun ]; then
		TO_EXEC="$MOUNT_POINT"/AppRun
	elif [ -f "$MOUNT_POINT"/Run ]; then
		# runimage uses Run instead of AppRun
		TO_EXEC="$MOUNT_POINT"/Run
	else
		_error "$TARGET does not contain an AppRun or Run file"
	fi
else
	TO_EXEC=/app/"$APPNAME"
fi

# Merge current array with bwrap array
ARRAY=$(_save_array "$TO_EXEC" "$@")
eval set -- "$BWRAP_ARRAY" -- "$ARRAY"

if [ ! -x "$TARGET" ] && [ "$IS_TRUSTED_ONCE" = 1 ]; then
	chmod +x "$TARGET" || true
fi

if [ -n "$SAS_XDG_OPEN_DAEMON" ]; then
	"$SAS_XDG_OPEN_DAEMON" &
	SAS_XDG_OPEN_DAEMON_PID=$!
fi

# Do the thing!
"$BWRAPCMD" "$@"
