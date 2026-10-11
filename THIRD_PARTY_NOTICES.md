# Third-party notices

The root MIT license applies to original Wifi Mancer code and documentation. It does not replace the terms of separately sourced data, dependencies or trademarks.

## Vendor database

`Resources/Data/oui.csv` is a compact transformation of the Wireshark/TShark manufacturer database. It includes Wireshark-specific descriptions as well as registry assignments; it must not be represented as an independently authored MIT dataset.

The data is retained under **GPL-2.0-or-later**, with copyright attributed to Wireshark contributors. See [the license text](LICENSES/GPL-2.0-or-later.txt) and [file provenance](Resources/Data/oui.csv.license). The original snapshot version/date was not recorded. Publication adds attribution headers on 2026-10-11 without changing entries. The compact CSV is editable text and is the shipped data source.

Primary sources: [generated upstream data](https://github.com/wireshark/wireshark/blob/master/epan/manuf-data.c), [generator](https://github.com/wireshark/wireshark/blob/master/tools/make-manuf.py), [canonical export](https://www.wireshark.org/download/automated/data/manuf.gz). The public snapshot omits redundant raw/compressed exports.

Do not label a distribution containing this dataset as wholly MIT. Binary packaging must retain applicable notices and source/license obligations; the source publication is not certification of a binary release. Replacing the database requires independently documented provenance and terms, not just stripping this notice.

## System and development components

- **libpcap:** the helper links the macOS SDK/system library. No Homebrew dylib is copied into this repository. Upstream libpcap is BSD licensed; consult its [license](https://github.com/the-tcpdump-group/libpcap/blob/master/LICENSE) before redistributing a separate copy.
- **Apple frameworks and SF Symbols:** used through platform APIs under Apple's terms. Apple trademarks and device model names belong to their owners; no affiliation is implied.
- **XcodeGen and Homebrew:** development tools invoked by scripts, not vendored project code. Their own terms apply.
- **Optional Arsenal executables:** recipe strings invoke external tools; the repository does not include their binaries or grant rights to them. Review each tool's license and platform support before packaging it.

## Artwork and fonts

The banner was generated with the built-in imagegen tool and approved for this project. Its prompt/provenance is in [docs/assets/banner.prompt.md](docs/assets/banner.prompt.md). It contains no live-network screenshot.

No Poppins or Lora font files are currently bundled. If font files or other assets are added, include their upstream license and attribution. Local fonts referenced by name are not redistributed by that reference.
