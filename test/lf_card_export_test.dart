import 'dart:convert';
import 'dart:typed_data';

import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HID Prox JSON exposes intuitive LF credential fields', () {
    final hid = HIDCard(
      hidType: 3,
      facilityCode: 2061,
      uid: Uint8List.fromList([0x00, 0x00, 0x00, 0x18, 0x0f]),
      issueLevel: 0,
      oem: 0,
    );
    final saved = CardSave(
      uid: hid.toString(),
      name: 'Prova LF',
      tag: TagType.hidProx,
    );

    final json = jsonDecode(saved.toJson()) as Map<String, dynamic>;
    final lf = json['lf'] as Map<String, dynamic>;

    expect(lf['technology'], 'HID Prox');
    expect(lf['format'], 'Indala 27-bit');
    expect(lf['facilityCode'], 2061);
    expect(lf['credentialNumber'], 6159);
    expect(lf['identifierHex'], '00 00 00 18 0F');
    expect((json['data'] as List<dynamic>), isEmpty);
  });

  test('the enriched JSON remains compatible with CardSave import', () {
    final hid = HIDCard(
      hidType: 3,
      facilityCode: 2061,
      uid: Uint8List.fromList([0x00, 0x00, 0x00, 0x18, 0x0f]),
      issueLevel: 0,
      oem: 0,
    );
    final original = CardSave(
      uid: hid.toString(),
      name: 'Prova LF',
      tag: TagType.hidProx,
    );

    final restored = CardSave.fromJson(original.toJson());
    final restoredHid = HIDCard.fromUID(restored.uid);

    expect(restored.tag, TagType.hidProx);
    expect(restoredHid.facilityCode, 2061);
    expect(restoredHid.credentialNumber, 6159);
  });
}
