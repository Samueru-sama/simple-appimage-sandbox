# simple-appimage-sandbox
Tool to sandbox AppImages with bubblewrap easily, written in POSIX shell.

Can also sandbox regular binaries and almost anything with an appended filesystem (RunImage, AppBundle, etc). 

Supports DwarFS and SquashFS filesystems.

Dependencies: 

```
	awk
	bwrap
	cut
	dwarfs
	grep
	head
	id
	md5sum
	readelf # Is there a way to get this done without this?
	readlink
	sed
	squashfuse
	tail
	umount
```

Credits: 

* Inspired by [aisap](https://github.com/mgord9518/aisap), including some compatible flags.
