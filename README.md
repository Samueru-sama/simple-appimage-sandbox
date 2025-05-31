# simple-appimage-sandbox
Tool to sandbox AppImages with bubblewrap easily, written in POSIX shell.

Can also sandbox regular binaries and almost anything with an appended filesystem (RunImage, AppBundle, etc). 

Supports DwarFS and SquashFS filesystems.

# Usage

`./sas.sh [OPTIONS] /path/to/app`

Example:

```
./sas.sh --rm-socket network --add-dir ~/"My randomdir" --add-dir xdg-download:rw ./My-random.AppImage
```

Options: 


* `--help`, `-h`, `-H` Display this help message and exit.

* `--version`, `-v`, `-V` Display the version of SAS and exit.

* `--data-dir`, `--sandboxed-home` specifies the location of the sandboxed home. Otherwise defaults to `ApplicationName.home` next to the application to sandbox.

* `--add-dir`, `--add-file` directory/file to give read access to. In order to add write access add `:rw` to the file, example `--add-dir /media/drive:rw`.

* `--no-config` Don't use existing configuration files, by default we try to give access to a directory matching the name of the given application in the following locations:  

```
XDG_CACHE_HOME
XDG_CONFIG_HOME
XDG_DATA_HOME
```

* `--no-theme` Don't share theme directories. By default read access to the following locations is given:

```
$XDG_DATA_HOME/icons
$XDG_DATA_HOME/themes
$XDG_CONFIG_HOME/dconf
$XDG_CONFIG_HOME/fontconfig
$XDG_CONFIG_HOME/gtk-3.0
$XDG_CONFIG_HOME/gtk3.0
$XDG_CONFIG_HOME/gtk-4.0
$XDG_CONFIG_HOME/gtk4.0
$XDG_CONFIG_HOME/kdeglobals
$XDG_CONFIG_HOME/Kvantum
$XDG_CONFIG_HOME/lxde
$XDG_CONFIG_HOME/qt5ct
$XDG_CONFIG_HOME/qt6ct

``` 

* `--rm-dir` remove a directory from the list of shared system directories, by default read access is given to the following locations: 

```
/bin
/etc
/lib
/lib32
/lib64
/opt
/sbin
/sys
/tmp
/usr/bin
/usr/lib
/usr/lib32
/usr/lib64
/usr/local
/usr/sbin
/usr/share

```

* `--add-socket` `--rm-socket` add and access to the following sockets, **note they are all enabled by default for now.**

```
audio (alsa and pulseaudio)
pipewire
dbus
network
x11
wayland
```

* `--level <Level>` Set the sandbox level, only level 1 is supported and used by default, this flag is for compatiblity with aisap.    

----------------------------------------------------------------------

Dependencies: 

```
awk
bwrap
cksum
dwarfs
grep
head
od
readlink
sed
squashfuse
tail
umount
```

Credits: 

* Inspired by [aisap](https://github.com/mgord9518/aisap), including some compatible flags.
