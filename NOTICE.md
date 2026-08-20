# Third-party components

The engine binary distributed from this repository's Releases page is a
combined work. Every component keeps its own licence; the list below is a
practical inventory, not legal advice.

## Shipped as separate files next to the engine

| File | Component | Licence |
|---|---|---|
| `libruby.so.3.1` | Ruby 3.1.3 (mkxp-z fork) | Ruby Licence / BSD-2-Clause |
| `libstdc++.so.6` | GCC C++ runtime | GPLv3 + GCC Runtime Library Exception |
| `libgomp.so.1` | GCC OpenMP runtime | GPLv3 + GCC Runtime Library Exception |
| `libgcc_s.so.1` | GCC low-level runtime | GPLv3 + GCC Runtime Library Exception |
| `exitwatch` | This project (`build/exitwatch.c`) | GPLv2+ |

## Linked into the engine binary

| Component | Licence |
|---|---|
| mkxp-z | GPLv2+ |
| SDL2, SDL_image, SDL_ttf, SDL_sound | Zlib |
| OpenAL Soft | LGPLv2+ |
| FluidSynth | LGPLv2.1+ |
| FreeType | FTL or GPLv2 |
| OpenSSL | Apache-2.0 |
| PhysicsFS | Zlib |
| libpng, zlib, bzip2 | permissive (respective project licences) |
| libogg, libvorbis, libtheora | BSD-3-Clause |
| Pixman | MIT |
| uchardet | MPL-1.1 / GPL / LGPL tri-licence |
| Liberation Sans (mkxp-z's bundled fallback font) | SIL Open Font Licence 1.1 |

## Note on the LGPL components

OpenAL Soft and FluidSynth are statically linked. The LGPL requires that
recipients be able to relink the work against modified versions of those
libraries. The build scripts in `build/` reproduce the entire binary from
published upstream sources and serve that purpose; every dependency is fetched
from its own upstream, unmodified except where a patch in `patches/` says
otherwise.

## Not included

No RPG Maker game data, assets, fonts belonging to a game, or fan-game content
is distributed here or in the Releases.
