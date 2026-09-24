# Every dependency, pinned. See nix/utils/fetch-source/default.nix for the two
# kinds of pins.
#
# Versions and commits are the ones plynic-libmpv-android pins
# (buildscripts/include/depinfo.sh), so both platforms build the same sources:
# git dependencies at the same commit (fetched here from their GitHub mirrors),
# release tarballs with the same sha256. libpng is Darwin-only (FreeType's PNG
# glyphs, e.g. colour emoji; Android's FreeType is built without it).
#
# mpv is not here: it is the flake input `plynic-mpv` (flake.nix), recorded
# with its NAR hash in flake.lock.
{
  dav1d = {
    version = "1.5.4";
    github = "videolan/dav1d";
    rev = "54706fc6bc0cdecab7e9593974a4039cc038fca7";
    hash = "sha256-L3a9MmPWJlxmRa19glWDLvkXHev5oiM5/fxtKOBPMxI=";
  };
  ffmpeg = {
    version = "8.1.3";
    github = "FFmpeg/FFmpeg";
    rev = "1041abdc962f4cc4f394aa8de9dc5236c0c3b9e7";
    hash = "sha256-i2R/HKonZwmkqWWy2U5eY5zSMx1rPkXNHPljN3qUiKQ=";
  };
  freetype = {
    version = "2.13.3";
    github = "freetype/freetype";
    rev = "42608f77f20749dd6ddc9e0536788eaad70ea4b5";
    hash = "sha256-4l90lDtpgm5xlh2m7ifrqNy373DTRTULRkAzicrM93c=";
  };
  fribidi = {
    version = "1.0.17";
    github = "fribidi/fribidi";
    rev = "b93119f5fdc7ea47672cc304c1455ffa6dfe7536";
    hash = "sha256-U3wVnCFnII09NqRcKCworhlGh30WETJkIDJQqcfU5b4=";
  };
  harfbuzz = {
    version = "11.5.1";
    github = "harfbuzz/harfbuzz";
    rev = "7497c4147469fd4102a7229222586ad5c743c5a1";
    hash = "sha256-hYyZwFa4M2c1hYkTWXuNT3Q1yz5SFgIUi5qF19vuv1Y=";
  };
  libass = {
    version = "0.17.5";
    github = "libass/libass";
    rev = "4a05d8127f525943ebf45fdc6497c9e665947f0d";
    hash = "sha256-srF0SPUNO2kISeNvub0sS5hvJXeIaaX8oZp3jXcHbZ0=";
  };
  # With its git submodules (glad, jinja, markupsafe, fast_float,
  # Vulkan-Headers, nuklear) at the commits the tag pins.
  libplacebo = {
    version = "7.360.1";
    github = "haasn/libplacebo";
    rev = "cee9b076f2c63104ccfd497fa79c39a867293ec4";
    submodules = true;
    hash = "sha256-2F3eUKjvAveahvqKuJFwHvIem9g156hCeKbeYBPovLk=";
  };
  libpng = {
    version = "1.6.58";
    url = "https://download.sourceforge.net/libpng/libpng-1.6.58.tar.xz";
    sha256 = "28eb403f51f0f7405249132cecfe82ea5c0ef97f1b32c5a65828814ae0d34775";
  };
  # meson build files for libpng, from the meson WrapDB
  libpngPatch = {
    version = "1.6.58-1";
    url = "https://wrapdb.mesonbuild.com/v2/libpng_1.6.58-1/get_patch";
    file = "libpng_1.6.58-1_patch.zip";
    sha256 = "6e9c6120317d701a9e909eb11f473d129581b8c0b662d0c6ec6a06495c3c0e46";
  };
  libxml2 = {
    version = "2.14.6";
    github = "GNOME/libxml2";
    rev = "d23960a130c5bb82779c9405fbbf85e65fb3c57c";
    hash = "sha256-EIcNL5B/o74hyc1N+ShrlKsPL5tHhiGgkCR1D7FcDjw=";
  };
  # The release tarball: a git checkout of the tag lacks the framework/
  # submodule the 3.6 build needs.
  mbedtls = {
    version = "3.6.7";
    url = "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-3.6.7/mbedtls-3.6.7.tar.bz2";
    sha256 = "a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6";
  };
  uchardet = {
    version = "0.0.8";
    url = "https://www.freedesktop.org/software/uchardet/releases/uchardet-0.0.8.tar.xz";
    sha256 = "e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0";
  };
}
