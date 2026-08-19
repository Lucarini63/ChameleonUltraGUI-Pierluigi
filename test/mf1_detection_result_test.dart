import 'dart:async';
import 'dart:typed_data';

import 'package:chameleonultragui/bridge/chameleon.dart';
import 'package:chameleonultragui/connector/serial_abstract.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';

void main() {
  group('MFKEY32 detection result download', () {
    test('stops after three empty responses', () async {
      final communicator = _ScriptedCommunicator(
        (_, __) => ChameleonMessage(
          command: ChameleonCommand.mf1GetDetectionResult.value,
          status: 0,
          data: Uint8List(0),
        ),
      );

      await expectLater(
        communicator.getMf1DetectionResult(2),
        throwsA(
          predicate((error) => error.toString().contains('0 di 2')),
        ),
      );
      expect(communicator.callCount, 3);
    });

    test('counts three no-progress responses after partial progress', () async {
      final communicator = _ScriptedCommunicator(
        (call, _) => ChameleonMessage(
          command: ChameleonCommand.mf1GetDetectionResult.value,
          status: 0,
          data: call == 1 ? _detectionRecord(uid: 1) : Uint8List(0),
        ),
      );

      await expectLater(
        communicator.getMf1DetectionResult(2),
        throwsA(
          predicate((error) => error.toString().contains('1 di 2')),
        ),
      );
      expect(communicator.callCount, 4);
    });

    test('propagates a send timeout immediately with MFKEY32 context',
        () async {
      final communicator = _ScriptedCommunicator(
        (_, __) => throw TimeoutException('timeout simulato'),
      );

      await expectLater(
        communicator.getMf1DetectionResult(2),
        throwsA(
          predicate((error) {
            final message = error.toString();
            return message.contains('MFKEY32') && message.contains('0 di 2');
          }),
        ),
      );
      expect(communicator.callCount, 1);
    });

    test('accepts slow progress until all five records are downloaded',
        () async {
      final communicator = _ScriptedCommunicator(
        (call, _) => ChameleonMessage(
          command: ChameleonCommand.mf1GetDetectionResult.value,
          status: 0,
          data: _detectionRecord(uid: call),
        ),
      );

      final result = await communicator.getMf1DetectionResult(5);

      expect(communicator.callCount, 5);
      expect(_recordCount(result), 5);
    });
  });

  group('sendCmd transport cleanup', () {
    test('removes the queued command when write throws', () async {
      final serial = _ThrowingSerial(Logger());
      final communicator = ChameleonCommunicator(Logger(), port: serial);
      final command = ChameleonCommand.getAppVersion;

      await expectLater(
        communicator.sendCmd(command),
        throwsA(isA<StateError>()),
      );

      expect(communicator.commandQueue.contains(command.value), isFalse);
    });

    test('times out when transport write never completes', () async {
      final serial = _HangingSerial(Logger());
      final communicator = ChameleonCommunicator(Logger(), port: serial);
      final command = ChameleonCommand.getAppVersion;
      final stopwatch = Stopwatch()..start();

      await expectLater(
        communicator.sendCmd(command),
        throwsA(
          isA<TimeoutException>().having(
            (error) => error.message,
            'message',
            contains('${command.value}'),
          ),
        ),
      );
      stopwatch.stop();

      expect(
          stopwatch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 5)));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 7)));
      expect(communicator.commandQueue.contains(command.value), isFalse);
    });
  });
}

typedef _ResponseBuilder = FutureOr<ChameleonMessage?> Function(
    int call, Uint8List? requestData);

class _ScriptedCommunicator extends ChameleonCommunicator {
  final _ResponseBuilder responseBuilder;
  int callCount = 0;

  _ScriptedCommunicator(this.responseBuilder) : super(Logger());

  @override
  Future<ChameleonMessage?> sendCmd(
    ChameleonCommand cmd, {
    Uint8List? data,
    Duration timeout = const Duration(seconds: 5),
    bool skipReceive = false,
    bool firstRun = false,
  }) async {
    callCount++;
    return responseBuilder(callCount, data);
  }
}

class _ThrowingSerial extends AbstractSerial {
  _ThrowingSerial(Logger logger) : super(log: logger) {
    isOpen = true;
  }

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) {
    return Future<bool>.error(StateError('write fallita'));
  }
}

class _HangingSerial extends AbstractSerial {
  final Completer<bool> _writeCompleter = Completer<bool>();

  _HangingSerial(Logger logger) : super(log: logger) {
    isOpen = true;
  }

  @override
  bool isManualConnectionSupported() => false;

  @override
  Future<List<Chameleon>> availableChameleons(bool onlyDFU) async => [];

  @override
  Future<bool> connectSpecificDevice(dynamic devicePort) async => false;

  @override
  Future<bool> write(Uint8List command, {bool firmware = false}) {
    return _writeCompleter.future;
  }
}

Uint8List _detectionRecord({required int uid}) {
  final data = Uint8List(18);
  data[0] = 4;
  data[1] = 0;
  final bytes = data.buffer.asByteData();
  bytes.setUint32(2, uid, Endian.big);
  bytes.setUint32(6, 0x01020304, Endian.big);
  bytes.setUint32(10, 0x05060708, Endian.big);
  bytes.setUint32(14, 0x090a0b0c, Endian.big);
  return data;
}

int _recordCount(
    Map<int, Map<int, Map<String, List<DetectionResult>>>> result) {
  var count = 0;
  for (final blocks in result.values) {
    for (final keyTypes in blocks.values) {
      for (final records in keyTypes.values) {
        count += records.length;
      }
    }
  }
  return count;
}
