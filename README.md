# Install the complete desktop

Boot the **NixOS installer USB in UEFI mode**, connect to the internet, open its terminal, and paste:

```bash
nix --extra-experimental-features 'nix-command flakes' run --refresh github:Roshrak/nixos-config#install
```

Choose the internal disk, type the requested `ERASE /dev/…` confirmation, then set the `aesc` login password when prompted. **All data on the selected disk will be replaced.** The command handles partitioning, mounting, **fresh hardware configuration**, the full NixOS build, desktop/apps, dotfiles, maintenance scripts, all wallpapers, and the bootloader. When it reports completion, shut down, remove the USB, and power on into the installed system.

This is my Intel x86_64 desktop setup, with the configured Hyprland, Plasma, GNOME, Niri, Sway, Mango and XFCE sessions. Private agent credentials and personal files are excluded. [Installation details and recovery](docs/LIVE-USB-INSTALL.md).

# All wallpapers

<table>
  <tr>
    <td><a href="wallpapers/120523661_p0.jpg"><img src="wallpapers/120523661_p0.jpg" width="300" alt="120523661_p0.jpg"></a></td>
    <td><a href="wallpapers/137155645_p0.jpg"><img src="wallpapers/137155645_p0.jpg" width="300" alt="137155645_p0.jpg"></a></td>
    <td><a href="wallpapers/Vocaloid-Hatsune-Miku-blue-blue-hair-fan-art-landscape-1499037-wallhere.com.jpg"><img src="wallpapers/Vocaloid-Hatsune-Miku-blue-blue-hair-fan-art-landscape-1499037-wallhere.com.jpg" width="300" alt="Vocaloid-Hatsune-Miku-blue-blue-hair-fan-art-landscape-1499037-wallhere.com.jpg"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/__morgan_le_fay_and_aesc_fate_and_1_more_drawn_by_antinese__70c1f8a98bb2390d224d09920b6242d0.jpg"><img src="wallpapers/__morgan_le_fay_and_aesc_fate_and_1_more_drawn_by_antinese__70c1f8a98bb2390d224d09920b6242d0.jpg" width="300" alt="__morgan_le_fay_and_aesc_fate_and_1_more_drawn_by_antinese__70c1f8a98bb2390d224d09920b6242d0.jpg"></a></td>
    <td><a href="wallpapers/__morgan_le_fay_and_aesc_fate_and_1_more_drawn_by_mento__f67538d98eaf6f373f3f6e0eb1ba8d49.jpg"><img src="wallpapers/__morgan_le_fay_and_aesc_fate_and_1_more_drawn_by_mento__f67538d98eaf6f373f3f6e0eb1ba8d49.jpg" width="300" alt="__morgan_le_fay_and_aesc_fate_and_1_more_drawn_by_mento__f67538d98eaf6f373f3f6e0eb1ba8d49.jpg"></a></td>
    <td><a href="wallpapers/__morgan_le_fay_fate_and_1_more_drawn_by_mochi_upamo__5a0064b23658cf009024bdb8bb13c707.jpg"><img src="wallpapers/__morgan_le_fay_fate_and_1_more_drawn_by_mochi_upamo__5a0064b23658cf009024bdb8bb13c707.jpg" width="300" alt="__morgan_le_fay_fate_and_1_more_drawn_by_mochi_upamo__5a0064b23658cf009024bdb8bb13c707.jpg"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/__morgan_le_fay_fate_and_1_more_drawn_by_reluvy__617c9c2c2600b9f4c49693f239d75f10.png"><img src="wallpapers/__morgan_le_fay_fate_and_1_more_drawn_by_reluvy__617c9c2c2600b9f4c49693f239d75f10.png" width="300" alt="__morgan_le_fay_fate_and_1_more_drawn_by_reluvy__617c9c2c2600b9f4c49693f239d75f10.png"></a></td>
    <td><a href="wallpapers/ashes_ash_firewood_130924_1920x1200.jpg"><img src="wallpapers/ashes_ash_firewood_130924_1920x1200.jpg" width="300" alt="ashes_ash_firewood_130924_1920x1200.jpg"></a></td>
    <td><a href="wallpapers/flower_sunflower_artificial_119551_1920x1200.jpg"><img src="wallpapers/flower_sunflower_artificial_119551_1920x1200.jpg" width="300" alt="flower_sunflower_artificial_119551_1920x1200.jpg"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/hatsune-miku-mclaren-gtr-and-the-fashionable-driver-27-1920x1200.jpg"><img src="wallpapers/hatsune-miku-mclaren-gtr-and-the-fashionable-driver-27-1920x1200.jpg" width="300" alt="hatsune-miku-mclaren-gtr-and-the-fashionable-driver-27-1920x1200.jpg"></a></td>
    <td><a href="wallpapers/hatsune-miku-twin-ponytails-jl-1920x1200.jpg"><img src="wallpapers/hatsune-miku-twin-ponytails-jl-1920x1200.jpg" width="300" alt="hatsune-miku-twin-ponytails-jl-1920x1200.jpg"></a></td>
    <td><a href="wallpapers/nanallynte.jpg"><img src="wallpapers/nanallynte.jpg" width="300" alt="nanallynte.jpg"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/nix.png"><img src="wallpapers/nix.png" width="300" alt="nix.png"></a></td>
    <td><a href="wallpapers/origami_plane_art_128345_1920x1200.jpg"><img src="wallpapers/origami_plane_art_128345_1920x1200.jpg" width="300" alt="origami_plane_art_128345_1920x1200.jpg"></a></td>
    <td><a href="wallpapers/panes.jpg"><img src="wallpapers/panes.jpg" width="300" alt="panes.jpg"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/pexels-irina-semenchik-257064265-17583073.jpg"><img src="wallpapers/pexels-irina-semenchik-257064265-17583073.jpg" width="300" alt="pexels-irina-semenchik-257064265-17583073.jpg"></a></td>
    <td><a href="wallpapers/pexels-lauripoldre-24963115.jpg"><img src="wallpapers/pexels-lauripoldre-24963115.jpg" width="300" alt="pexels-lauripoldre-24963115.jpg"></a></td>
    <td><a href="wallpapers/rose_flower_white_143143_1920x1200.jpg"><img src="wallpapers/rose_flower_white_143143_1920x1200.jpg" width="300" alt="rose_flower_white_143143_1920x1200.jpg"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/snowy-map.png"><img src="wallpapers/snowy-map.png" width="300" alt="snowy-map.png"></a></td>
    <td><a href="wallpapers/stairs_dark_bw_126426_1920x1200.jpg"><img src="wallpapers/stairs_dark_bw_126426_1920x1200.jpg" width="300" alt="stairs_dark_bw_126426_1920x1200.jpg"></a></td>
    <td><a href="wallpapers/swirls.jpg"><img src="wallpapers/swirls.jpg" width="300" alt="swirls.jpg"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/swirly-painting.jpg"><img src="wallpapers/swirly-painting.jpg" width="300" alt="swirly-painting.jpg"></a></td>
    <td><a href="wallpapers/tank.jpg"><img src="wallpapers/tank.jpg" width="300" alt="tank.jpg"></a></td>
    <td><a href="wallpapers/tree-stump.jpg"><img src="wallpapers/tree-stump.jpg" width="300" alt="tree-stump.jpg"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/tree.jpg"><img src="wallpapers/tree.jpg" width="300" alt="tree.jpg"></a></td>
    <td><a href="wallpapers/vocaloid-hatsune-miku-anime-girl-3d-1920x1200.jpg"><img src="wallpapers/vocaloid-hatsune-miku-anime-girl-3d-1920x1200.jpg" width="300" alt="vocaloid-hatsune-miku-anime-girl-3d-1920x1200.jpg"></a></td>
    <td><a href="wallpapers/wallhaven-5ykdq8.png"><img src="wallpapers/wallhaven-5ykdq8.png" width="300" alt="wallhaven-5ykdq8.png"></a></td>
  </tr>
  <tr>
    <td><a href="wallpapers/wallhaven-ogylom.png"><img src="wallpapers/wallhaven-ogylom.png" width="300" alt="wallhaven-ogylom.png"></a></td>
    <td><a href="wallpapers/wallpaperflare.com_wallpaper.jpg"><img src="wallpapers/wallpaperflare.com_wallpaper.jpg" width="300" alt="wallpaperflare.com_wallpaper.jpg"></a></td>
    <td><a href="wallpapers/wp16058089-cartoon-miku-wallpapers.jpg"><img src="wallpapers/wp16058089-cartoon-miku-wallpapers.jpg" width="300" alt="wp16058089-cartoon-miku-wallpapers.jpg"></a></td>
  </tr>
</table>
