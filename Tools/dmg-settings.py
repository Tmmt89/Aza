"""Finder layout for dmgbuild; positions are in points, matching dmg-background.swift."""
files = [(defines["app"], "Aza.app")]
symlinks = {"Applications": "/Applications"}
# Не менять FinderInfo подписанного .app: это нарушает codesign --strict.
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
window_rect = ((200, 200), (640, 380))
default_view = "icon-view"
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
arrange_by = None
icon_size = 112
text_size = 14
icon_locations = {"Aza.app": (160, 190), "Applications": (480, 190)}
