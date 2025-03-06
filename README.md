# acr122_pcsc

## Overview

acr122_pcsc is a Dart library that provides a high-level interface for interacting with ACR122 NFC/RFID readers. Built on top of the pcsc_wrapper, this library simplifies access to ACR122 devices through easy-to-use commands and abstractions.

## Platform Support

⚠️ **Platform Limitations**:
- Currently only supports Linux and MacOS
- Only the Linux implementation is tested
- Windows support is not present

## Features

- Utilizes pcsc_wrapper for low-level PC/SC bindings
- Simplified API for ACR122 reader interactions
- Easy-to-use methods for NFC/RFID operations
- Streamlined device communication
- Lightweight and efficient Dart implementation

## Dependencies

This library depends on the pcsc_wrapper for its underlying PC/SC bindings, providing a clean abstraction layer over the raw PC/SC interface specifically tailored for ACR122 readers.

## Prerequisites

- Dart SDK
- PC/SC middleware installed on your system
- libpcsclite-dev (on Linux)
- ACR122 NFC/RFID reader

## Installation

Add the following to your `pubspec.yaml`:

```yaml
dependencies:
  acr122_pcsc: ^[version]
```

## License

This project is licensed under the BSD 3-Clause License. See the LICENSE file for details.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Disclaimer

This library is provided "as-is" with no guarantee of compatibility or support. Users should thoroughly test in their specific environments.