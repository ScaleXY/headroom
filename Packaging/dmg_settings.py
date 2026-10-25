# dmgbuild settings for Headroom-<version>.dmg; the Makefile passes app=<path to Headroom.app>.
# Icon positions match the layout drawn by Scripts/dmg_background.py.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions =[os.path.basename(app)]
badge_icon = None

background = "assets/dmg-background.tiff"
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    os.path.basename(app): (170, 210),
    "Applications": (470, 210),
}
