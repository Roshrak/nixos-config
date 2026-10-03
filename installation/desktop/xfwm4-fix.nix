# Guard xfwm4's compositor lookup when an external compositor such as Picom
# owns compositing. Upstream fix for the repeated GLib hash-table warning on
# xfwm4 4.20.0; patch was dry-run against the pinned nixpkgs source.
{ ... }:

{
  nixpkgs.overlays = [
    (_final: prev: {
      xfwm4 = prev.xfwm4.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchurl {
            url = "https://github.com/xfce-mirror/xfwm4/commit/69a16352c9b0b6591099f63a306238272db58b3a.patch";
            hash = "sha256-cSstLzkSzEVowYQ66FMeVvu1x+XVc6k+zksWHsDvQlE=";
          })
        ];
      });
    })
  ];
}
