import 'dart:typed_data';

import 'package:chameleonultragui/helpers/mifare_ultralight/password_audit.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NTAG protection parser', () {
    test('detects read/write protection with unlimited attempts', () {
      final info = parseNtagProtectionResponse(
        Uint8List.fromList([0x00, 0x00, 0x00, 0x04, 0x80, 0, 0, 0]),
        41,
      );

      expect(info.readable, isTrue);
      expect(info.protectionEnabled, isTrue);
      expect(info.protectsRead, isTrue);
      expect(info.authLimit, 0);
      expect(info.dictionaryAuditAllowed, isTrue);
    });

    test('refuses dictionary audit when AUTHLIM is enabled', () {
      final info = parseNtagProtectionResponse(
        Uint8List.fromList([0x00, 0x00, 0x00, 0x04, 0x83, 0, 0, 0]),
        41,
      );

      expect(info.authLimit, 3);
      expect(info.dictionaryAuditAllowed, isFalse);
    });

    test('recognizes disabled or unreadable protection', () {
      final disabled = parseNtagProtectionResponse(
        Uint8List.fromList([0x00, 0x00, 0x00, 0xff, 0x00, 0, 0, 0]),
        41,
      );
      final unreadable =
          parseNtagProtectionResponse(Uint8List.fromList([0x00]), 41);

      expect(disabled.protectionEnabled, isFalse);
      expect(disabled.dictionaryAuditAllowed, isFalse);
      expect(unreadable.readable, isFalse);
    });
  });

  group('NTAG automatic read planner', () {
    NtagProtectionInfo protection({
      bool readable = true,
      int auth0 = 4,
      bool protectsRead = true,
      int authLimit = 0,
    }) =>
        NtagProtectionInfo(
          readable: readable,
          totalPages: 41,
          auth0: auth0,
          protectsRead: protectsRead,
          authLimit: authLimit,
        );

    test('stops after a complete passive read', () {
      expect(
        decideNtagAutomaticRead(
          protection: protection(),
          inaccessiblePages: 0,
        ),
        NtagAutomaticReadDecision.completeWithoutPassword,
      );
    });

    test('does not authenticate for write-only protection', () {
      expect(
        decideNtagAutomaticRead(
          protection: protection(protectsRead: false),
          inaccessiblePages: 3,
        ),
        NtagAutomaticReadDecision.retryWithoutPassword,
      );
    });

    test('authenticates only for read protection with unlimited attempts', () {
      expect(
        decideNtagAutomaticRead(
          protection: protection(),
          inaccessiblePages: 3,
        ),
        NtagAutomaticReadDecision.authenticate,
      );
      expect(
        decideNtagAutomaticRead(
          protection: protection(authLimit: 2),
          inaccessiblePages: 3,
        ),
        NtagAutomaticReadDecision.stopForSafety,
      );
    });

    test('stops when AUTHLIM cannot be read', () {
      expect(
        decideNtagAutomaticRead(
          protection: protection(readable: false),
          inaccessiblePages: 3,
        ),
        NtagAutomaticReadDecision.stopForSafety,
      );
    });
  });

  test('dictionary parser accepts only unique four-byte passwords', () {
    final passwords = parseNtagPasswordDictionary('''
# comment
FFFFFFFF
00000000 # factory test
ffffffff
1234
NOT_HEX!!
11223344
''');

    expect(passwords.map((value) => value.toList()), [
      [0xff, 0xff, 0xff, 0xff],
      [0x00, 0x00, 0x00, 0x00],
      [0x11, 0x22, 0x33, 0x44],
    ]);
  });

  test('saved-card metadata preserves a verified NTAG password', () {
    final extra = CardSaveExtra(
      ultralightPassword: Uint8List.fromList([0x11, 0x22, 0x33, 0x44]),
    );

    final restored = CardSaveExtra.import(extra.export());
    expect(restored.ultralightPassword, [0x11, 0x22, 0x33, 0x44]);
  });
}
