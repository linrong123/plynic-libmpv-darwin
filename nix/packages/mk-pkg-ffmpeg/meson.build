# https://mesonbuild.com/External-Project-module.html

project('ffmpeg', 'c', 'cpp', 'objc')

mod = import('unstable-external_project')

# build binaries
c = meson.get_compiler('c')
cpp = meson.get_compiler('cpp')
objc = meson.get_compiler('objc')
nm = find_program('nm')
ar = find_program('ar')
strip = find_program('strip')
pkg_config = find_program('pkg-config')

# build options
c_args = get_option('c_args')
cpp_args = get_option('cpp_args')
objc_args = get_option('objc_args')
c_link_args = get_option('c_link_args')

# parameters
variant = get_option('variant')
flavor = get_option('flavor')

# options
disable_all_options = [
    '--disable-autodetect',
    '--disable-all',
    '--disable-x86asm',
    '--disable-runtime-cpudetect',
    '--disable-debug',
    '--disable-stripping',
    '--disable-optimizations',
    '--disable-static',
    '--disable-shared',
    '--disable-pthreads',
    '--disable-safe-bitstream-reader',
]

common_options = [
    '--prefix=@PREFIX@',
    # -Os for all of FFmpeg, as on Android for now; dropping it on both
    # platforms waits for an -Os/-O3 comparison on a 32-bit TV (plynic spec
    # 0017 TD7)
    '--enable-small', # reduce libs size
    '--enable-optimizations',
    '--enable-shared',
    '--enable-network',
    '--enable-pthreads',
    '--enable-pic',
    '--enable-mbedtls', # tls support (mbedtls)
    '--enable-version3',
    '--enable-safe-bitstream-reader',
    # unstripped, so that mk-dsyms can follow the debug map; the frameworks
    # are stripped after that (mk-out-libs)
    '--disable-stripping',
    '--enable-avcodec',
    '--enable-avformat',
    '--enable-swresample',
    '--enable-swscale',
    '--enable-avfilter',

    # '--enable-gpl', # uncomment it to include GPL code
    # '--enable-nonfree', # uncomment it to include unredistributable code
]

audio_common_options = [
    '--enable-zlib', # rasc support
    '--enable-audiotoolbox',
]

video_common_options = [
    '--enable-neon', # improve hevc (h265) support on arm
    '--enable-libxml2', # dash support
    '--enable-videotoolbox',
    '--enable-libdav1d', # av1 support
]

audio_full_options = [
    '--enable-decoders',
    '--enable-hwaccels',
    '--enable-parsers',
    '--enable-demuxers',
    '--enable-protocols',
    '--enable-bsfs',

    # filters
    '--enable-filter=overlay',
    '--enable-filter=equalizer',

    # TODO: `media_kit` checks the presence of the h264 decoder to determine if
    # `ffmpeg` is an audio or video variant, so we disable it for the audio
    # variant.
    # Ideally, we should only enable the audio decoders…
    '--disable-decoder=h264',
]

video_full_options = [
    '--enable-decoder=h264',
]

# plynic = full + the spdif muxer (bitstream passthrough groundwork; a muxer
# costs nothing until an AO asks for it), like plynic-libmpv-android's
# `plynic` flavor
video_plynic_options = [
    '--enable-muxer=spdif',
]

# disable all option
options = disable_all_options

# common
options += common_options
options += audio_common_options
if variant == 'video'
    options += video_common_options
endif

# components
if flavor == 'plynic'
    options += audio_full_options
    options += video_full_options
    options += video_plynic_options
endif

p = mod.add_project('configure',
    configure_options : options,
    cross_configure_options: [
        '--enable-cross-compile',
        '--target-os=@0@'.format(host_machine.system()),
        '--arch=@0@'.format(host_machine.cpu_family()),

        '--nm=@0@'.format(nm.path()),
        '--ar=@0@'.format(ar.path()),
        '--as=@0@'.format(''.join(c.cmd_array())),
        '--strip=@0@'.format(strip.path()),
        '--cc=@0@'.format(''.join(c.cmd_array())),
        '--cxx=@0@'.format(''.join(cpp.cmd_array())),
        '--objcc=@0@'.format(''.join(objc.cmd_array())),
        '--ld=@0@'.format(''.join(c.cmd_array())),
        '--pkg-config=@0@'.format(pkg_config.path()),

        '--host-cc=@0@'.format(''.join(c.cmd_array())),
        '--host-ld=@0@'.format(''.join(c.cmd_array())),

        '--extra-cflags=@0@'.format(' '.join(c_args)),
        '--extra-cxxflags=@0@'.format(' '.join(cpp_args)),
        '--extra-objcflags=@0@'.format(' '.join(objc_args)),
        '--extra-ldflags=@0@'.format(' '.join(c_link_args)),
    ],
    verbose: true,
)

libavfilter_dep = p.dependency('avfilter')
libswscale_dep = p.dependency('swscale')
libavcodec_dep = p.dependency('avcodec')
libavformat_dep = p.dependency('avformat')
libavutil_dep = p.dependency('avutil')
libswresample_dep = p.dependency('swresample')

meson.override_dependency('libavfilter', libavfilter_dep)
meson.override_dependency('libswscale', libswscale_dep)
meson.override_dependency('libavcodec', libavcodec_dep)
meson.override_dependency('libavformat', libavformat_dep)
meson.override_dependency('libavutil', libavutil_dep)
meson.override_dependency('libswresample', libswresample_dep)
