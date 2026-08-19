import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/mifare_classic/recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MIFARE Classic attack planner', () {
    test('uses Nested directly when a base key is available', () {
      final plan = buildMifareClassicAttackPlan(
        prng: NTLevel.weak,
        hasBackdoor: false,
        isStaticEncrypted: false,
        foundKeys: 3,
        missingKeys: 29,
      );

      expect(plan.steps, [MifareClassicAttackMethod.nested]);
    });

    test('uses Darkside before Nested when no base key is available', () {
      final plan = buildMifareClassicAttackPlan(
        prng: NTLevel.weak,
        hasBackdoor: false,
        isStaticEncrypted: false,
        foundKeys: 0,
        missingKeys: 32,
      );

      expect(plan.steps, [
        MifareClassicAttackMethod.darkside,
        MifareClassicAttackMethod.nested,
      ]);
    });

    test('uses backdoor for static encrypted cards', () {
      final plan = buildMifareClassicAttackPlan(
        prng: NTLevel.hard,
        hasBackdoor: true,
        isStaticEncrypted: true,
        foundKeys: 0,
        missingKeys: 32,
      );

      expect(plan.steps, [MifareClassicAttackMethod.backdoor]);
    });

    test('stops when static PRNG has no base key or backdoor', () {
      final plan = buildMifareClassicAttackPlan(
        prng: NTLevel.static,
        hasBackdoor: false,
        isStaticEncrypted: false,
        foundKeys: 0,
        missingKeys: 32,
      );

      expect(plan.steps, isEmpty);
    });

    test('stops static encrypted recovery when backdoor is unavailable', () {
      final plan = buildMifareClassicAttackPlan(
        prng: NTLevel.hard,
        hasBackdoor: false,
        isStaticEncrypted: true,
        foundKeys: 1,
        missingKeys: 31,
      );

      expect(plan.steps, isEmpty);
    });

    test('does not plan recovery when no keys are missing', () {
      final plan = buildMifareClassicAttackPlan(
        prng: NTLevel.weak,
        hasBackdoor: false,
        isStaticEncrypted: false,
        foundKeys: 32,
        missingKeys: 0,
      );

      expect(plan.steps, isEmpty);
    });
  });
}
