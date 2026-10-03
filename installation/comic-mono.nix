{ pkgs, ... }:

let
  comicMono = pkgs.stdenvNoCC.mkDerivation {
    pname = "comic-mono";
    version = "2019-06-07";

    src = ./fonts/comic-mono;

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      mkdir -p $out/share/fonts/truetype/comic-mono
      cp $src/ComicMono.ttf \
        $out/share/fonts/truetype/comic-mono/ComicMono.ttf
      cp $src/ComicMono-Bold.ttf \
        $out/share/fonts/truetype/comic-mono/ComicMono-Bold.ttf
    '';
  };
in
{
  fonts.packages = [ comicMono ];

  # Make Comic Mono the generic UI + terminal default.
  fonts.fontconfig.defaultFonts = {
    sansSerif = [ "Comic Mono" ];
    monospace = [ "Comic Mono" ];
  };
}
