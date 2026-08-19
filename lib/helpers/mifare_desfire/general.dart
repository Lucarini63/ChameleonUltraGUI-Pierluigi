import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';

const int _desfireReaderApduCommand = 6004;

class MifareDesfireInfo {
  final bool iso14443_4;
  final bool apduSupported;
  final bool confirmed;
  final Uint8List? versionFrame;
  final int? vendorId;
  final int? hardwareType;
  final int? hardwareSubtype;
  final int? hardwareMajor;
  final int? hardwareMinor;
  final int? storageCode;
  final int? protocol;

  const MifareDesfireInfo({
    this.iso14443_4 = true,
    this.apduSupported = false,
    this.confirmed = false,
    this.versionFrame,
    this.vendorId,
    this.hardwareType,
    this.hardwareSubtype,
    this.hardwareMajor,
    this.hardwareMinor,
    this.storageCode,
    this.protocol,
  });

  bool get isLight => confirmed && (hardwareType! & 0x0f) == 0x08;

  String? get generation {
    if (!confirmed) return null;
    if (isLight) return 'Light';
    switch (hardwareMajor! & 0x0f) {
      case 1:
        return 'EV1';
      case 2:
        return 'EV2';
      case 3:
        return 'EV3';
      default:
        return null;
    }
  }

  bool get supportsAes =>
      confirmed &&
      (isLight || const ['EV1', 'EV2', 'EV3'].contains(generation));

  String get displayName {
    final suffix = generation;
    return suffix == null ? 'MIFARE DESFire' : 'MIFARE DESFire $suffix';
  }

  int? get storageBytes {
    final code = storageCode;
    if (code == null) return null;
    final exponent = code >> 1;
    if (exponent < 0 || exponent > 30) return null;
    return 1 << exponent;
  }

  bool get isExactStorageSize => storageCode != null && storageCode! & 1 == 0;
}

/// Parses the first frame returned by the DESFire GetVersion command.
/// Layout: vendor, product type, subtype, HW major, HW minor, size, protocol,
/// followed by ISO status 91 AF (or 91 00).
MifareDesfireInfo parseMifareDesfireGetVersion(Uint8List response) {
  if (response.length < 9 ||
      response[response.length - 2] != 0x91 ||
      !const [0xaf, 0x00].contains(response.last)) {
    return const MifareDesfireInfo(apduSupported: true);
  }

  final hardwareType = response[1];
  final family = hardwareType & 0x0f;
  final hardwareMajor = response[3];
  // 0xA0 identifies MIFARE DUOX, which shares family code 0x01.
  final isDesfire = response[0] == 0x04 &&
      (family == 0x01 || family == 0x08) &&
      hardwareMajor != 0xa0;
  if (!isDesfire) {
    return MifareDesfireInfo(
      apduSupported: true,
      versionFrame: Uint8List.fromList(response),
    );
  }

  return MifareDesfireInfo(
    apduSupported: true,
    confirmed: true,
    versionFrame: Uint8List.fromList(response),
    vendorId: response[0],
    hardwareType: hardwareType,
    hardwareSubtype: response[2],
    hardwareMajor: hardwareMajor,
    hardwareMinor: response[4],
    storageCode: response[5],
    protocol: response[6],
  );
}

Future<MifareDesfireInfo> identifyMifareDesfire(
    ChameleonCommunicator communicator) async {
  try {
    final capabilities = await communicator.getDeviceCapabilities();
    if (!capabilities.contains(_desfireReaderApduCommand)) {
      return const MifareDesfireInfo();
    }

    final response = await communicator.send14A4Apdu(
      Uint8List.fromList(const [0x90, 0x60, 0x00, 0x00, 0x00]),
    );
    return parseMifareDesfireGetVersion(response);
  } catch (_) {
    // A Type 4 card may not be DESFire, or it may have left the RF field.
    // Keep the successful anticollision result instead of failing the scan.
    return const MifareDesfireInfo(apduSupported: true);
  }
}
