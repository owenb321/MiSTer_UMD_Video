# Loading a movie

Open the OSD and choose **Load Video**. The picker accepts `.iso` images of UMD Video discs,
and `.mps` files: a single clip's stream taken out of an image
([A single stream file](images.md#a-single-stream-file-mps)). The core tells the two apart by
what the file holds, not by its name.

When the core is launched with nothing loaded, the OSD opens on its own after about a
second so you land in the file picker. With the UMD Main and a PSP sharing its disc over USB,
the core plays that disc instead ([Playing a real UMD](psp-disc.md)).

## The idle screen

With nothing loaded the core shows a slowly moving wave in the style of the PSP's home
screen. Its colour follows the calendar month, taken from the MiSTer's clock.

Loading an image plays its main title: the idle screen gives way to the film, and the
disc-activity LED lights while the image is read. A disc the core cannot play says so
([On-screen messages](../playback/on-screen-messages.md)). Stop brings the idle screen back ([Controls](../playback/controls.md)),
or, with the UMD Main installed, the disc's own art ([The disc screen](../playback/disc-menus.md#the-disc-screen)).

## Launching from an MGL

An MGL shortcut loads the core and mounts an image in one step:

```xml
<mistergamedescription>
  <rbf>_Other/UMD</rbf>
  <file delay="2" type="s" index="0" path="/media/fat/games/UMD/Movie.iso"/>
</mistergamedescription>
```
