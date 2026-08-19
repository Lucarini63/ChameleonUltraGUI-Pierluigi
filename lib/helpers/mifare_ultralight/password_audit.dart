import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/mifare_ultralight/general.dart';
import 'package:flutter/services.dart';

const String ntagAuditDictionaryAsset = 'assets/dictionaries/ntag_audit.dic';

enum NtagAutomaticReadDecision {
  completeWithoutPassword,
  retryWithoutPassword,
  authenticate,
  stopForSafety,
}

class NtagProtectionInfo {
  final bool readable;
  final int? auth0;
  final bool protectsRead;
  final bool configurationLocked;
  final int? authLimit;
  final int totalPages;

  const NtagProtectionInfo({
    required this.readable,
    required this.totalPages,
    this.auth0,
    this.protectsRead = false,
    this.configurationLocked = false,
    this.authLimit,
  });

  bool get protectionEnabled =>
      readable && auth0 != null && auth0! < totalPages;

  bool get dictionaryAuditAllowed =>
      readable && protectionEnabled && authLimit == 0;
}

NtagAutomaticReadDecision decideNtagAutomaticRead({
  required NtagProtectionInfo protection,
  required int inaccessiblePages,
}) {
  if (inaccessiblePages == 0) {
    return NtagAutomaticReadDecision.completeWithoutPassword;
  }

  // If the configuration cannot be read, AUTHLIM is unknown. In that case an
  // automatic password attempt could consume one of a limited number of tries.
  if (!protection.readable) {
    return NtagAutomaticReadDecision.stopForSafety;
  }

  // A disabled protection or PROT=W never requires authentication for reads.
  // Missing pages in this case are communication errors, not a password prompt.
  if (!protection.protectionEnabled || !protection.protectsRead) {
    return NtagAutomaticReadDecision.retryWithoutPassword;
  }

  if (protection.authLimit != 0) {
    return NtagAutomaticReadDecision.stopForSafety;
  }

  return NtagAutomaticReadDecision.authenticate;
}

NtagProtectionInfo parseNtagProtectionResponse(
    Uint8List response, int totalPages) {
  // READ from CFG0 returns CFG0 at bytes 0..3 and CFG1 at bytes 4..7.
  if (response.length < 8) {
    return NtagProtectionInfo(readable: false, totalPages: totalPages);
  }

  final auth0 = response[3];
  final access = response[4];
  return NtagProtectionInfo(
    readable: true,
    totalPages: totalPages,
    auth0: auth0,
    protectsRead: access & 0x80 != 0,
    configurationLocked: access & 0x40 != 0,
    authLimit: access & 0x07,
  );
}

List<Uint8List> parseNtagPasswordDictionary(String contents,
    {int maximumEntries = 64}) {
  final passwords = <Uint8List>[];
  final seen = <String>{};
  for (var line in contents.split(RegExp(r'\r?\n'))) {
    final value = line.split('#').first.trim().toUpperCase();
    if (value.length != 8 || !isValidHexString(value) || !seen.add(value)) {
      continue;
    }
    passwords.add(hexToBytes(value));
    if (passwords.length >= maximumEntries) break;
  }
  return passwords;
}

Future<List<Uint8List>> loadNtagAuditDictionary() async {
  final contents = await rootBundle.loadString(ntagAuditDictionaryAsset);
  return parseNtagPasswordDictionary(contents);
}

Future<NtagProtectionInfo> readNtagProtectionInfo(
    ChameleonCommunicator communicator, TagType type) async {
  final totalPages = mfUltralightGetPagesCount(type);
  final passwordPage = mfUltralightGetPasswordPage(type);
  if (totalPages == 0 || passwordPage < 2) {
    return NtagProtectionInfo(readable: false, totalPages: totalPages);
  }

  try {
    final response = await communicator.send14ARaw(
      Uint8List.fromList([0x30, passwordPage - 2]),
    );
    return parseNtagProtectionResponse(response, totalPages);
  } catch (_) {
    return NtagProtectionInfo(readable: false, totalPages: totalPages);
  }
}

Future<Uint8List?> verifyNtagPassword(
    ChameleonCommunicator communicator, Uint8List password,
    {bool keepRfField = false}) async {
  try {
    final response = await communicator.send14ARaw(
      Uint8List.fromList([0x1b, ...password]),
      keepRfField: keepRfField,
      checkResponseCrc: true,
    );
    return response.length >= 2
        ? Uint8List.fromList(response.sublist(0, 2))
        : null;
  } catch (_) {
    return null;
  }
}
