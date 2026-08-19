import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';
import 'package:chameleonultragui/gui/menu/pages/mfkey32.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/sharedprefsprovider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('MFKEY32 stops and requires a manual restart after disconnection',
      (tester) async {
    final connector = _FakeSerial(Logger())..connected = true;
    final communicator = _FakeCommunicator();
    final appState = ChameleonGUIState(SharedPreferencesProvider())
      ..connector = connector
      ..communicator = communicator;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: appState,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Mfkey32Menu(slot: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Start MFKEY32 acquisition'), findsOneWidget);
    await tester.tap(find.text('Start MFKEY32 acquisition'));
    await tester.pumpAndSettle();
    expect(communicator.detectionCountCalls, 1);
    expect(find.text('Stop'), findsOneWidget);

    connector.connected = false;
    appState.changesMade();
    await tester.pump();

    expect(
      find.text(
        'Chameleon disconnected. Reconnect it, press Check again, and restart MFKEY32.',
      ),
      findsOneWidget,
    );
    expect(find.text('Stop'), findsNothing);
    expect(find.text('Check again'), findsOneWidget);
    expect(find.text('0'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    expect(communicator.detectionCountCalls, 1);

    connector.connected = true;
    appState.changesMade();
    await tester.pump(const Duration(seconds: 2));
    expect(communicator.detectionCountCalls, 1);
    expect(find.text('Check again'), findsOneWidget);

    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(find.text('Start MFKEY32 acquisition'), findsOneWidget);
    expect(communicator.detectionCountCalls, 1);

    await tester.tap(find.text('Start MFKEY32 acquisition'));
    await tester.pumpAndSettle();
    expect(communicator.detectionCountCalls, 2);
    expect(communicator.detectionStatusChanges, [false, true]);
  });

  testWidgets('MFKEY32 treats a transport timeout as a lost session',
      (tester) async {
    final connector = _FakeSerial(Logger())..connected = true;
    final communicator = _FakeCommunicator()
      ..detectionCountError = TimeoutException('transport unavailable');
    final appState = ChameleonGUIState(SharedPreferencesProvider())
      ..connector = connector
      ..communicator = communicator;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: appState,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Mfkey32Menu(slot: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start MFKEY32 acquisition'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Chameleon disconnected. Reconnect it, press Check again, and restart MFKEY32.',
      ),
      findsOneWidget,
    );
    expect(find.text('Check again'), findsOneWidget);
    expect(find.textContaining('TimeoutException'), findsNothing);
  });
}

class _FakeCommunicator extends ChameleonCommunicator {
  int detectionCountCalls = 0;
  Object? detectionCountError;
  final List<bool> detectionStatusChanges = [];

  _FakeCommunicator() : super(Logger());

  @override
  Future<List<SlotTypes>> getSlotTagTypes() async => List.generate(
        8,
        (index) => SlotTypes(
          hf: index == 0 ? TagType.mifare1K : TagType.unknown,
        ),
      );

  @override
  Future<int> getActiveSlot() async => 0;

  @override
  Future<bool> isReaderDeviceMode() async => false;

  @override
  Future<void> setReaderDeviceMode(bool readerMode) async {}

  @override
  Future<void> activateSlot(int slot) async {}

  @override
  Future<bool> isMf1DetectionMode() async => true;

  @override
  Future<void> setMf1DetectionStatus(bool status) async {
    detectionStatusChanges.add(status);
  }

  @override
  Future<int> getMf1DetectionCount() async {
    detectionCountCalls++;
    if (detectionCountError case final error?) throw error;
    return 0;
  }
}

class _FakeSerial extends AbstractSerial {
  _FakeSerial(Logger logger) : super(log: logger);

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) async => true;
}
