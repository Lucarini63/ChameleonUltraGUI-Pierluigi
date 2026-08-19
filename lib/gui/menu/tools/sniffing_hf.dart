import 'package:chameleonultragui/gui/menu/tools/sniffing_common.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/general.dart';
import 'package:chameleonultragui/helpers/sniffing.dart';
import 'package:chameleonultragui/main.dart';
import 'package:chameleonultragui/recovery/recovery.dart' as recovery;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class HFSniffingMenu extends StatefulWidget {
  const HFSniffingMenu({super.key});

  @override
  State<HFSniffingMenu> createState() => _HFSniffingMenuState();
}

class _HFSniffingMenuState extends State<HFSniffingMenu> {
  final _timeoutController = TextEditingController(text: '5000');
  Uint8List _rawCapture = Uint8List(0);
  List<HFSniffFrame> _frames = const [];
  List<HFSniffNonce> _nonces = const [];
  final List<_RecoveredSniffKey> _recoveredKeys = [];
  bool _capturing = false;
  bool _recovering = false;
  int _recoveryDone = 0;
  int _recoveryTotal = 0;
  String? _error;
  String? _status;

  SniffingText get text =>
      SniffingText(Localizations.localeOf(context).languageCode == 'it');

  @override
  void dispose() {
    _timeoutController.dispose();
    super.dispose();
  }

  void _applyCapture(Uint8List data, String status) {
    final frames = parseHFSniffFrames(data);
    final nonces = extractHFSniffNonces(frames);
    setState(() {
      _rawCapture = data;
      _frames = frames;
      _nonces = nonces;
      _recoveredKeys.clear();
      _error = frames.isEmpty ? 'Il file non contiene frame HF validi.' : null;
      _status = status;
    });
  }

  Future<void> _capture() async {
    final appState = context.read<ChameleonGUIState>();
    if (!appState.connector!.connected || _capturing) return;
    final timeout =
        (int.tryParse(_timeoutController.text) ?? 5000).clamp(1, 30000);
    setState(() {
      _capturing = true;
      _error = null;
      _status = text.capturing;
    });
    try {
      final capabilities = await appState.communicator!.getDeviceCapabilities();
      if (!capabilities.contains(ChameleonCommand.hf14ASniff.value)) {
        throw Exception(text.unsupportedFirmware);
      }
      final result = await appState.communicator!.sniffHF(timeoutMs: timeout);
      if (!mounted) return;
      _applyCapture(result, text.captured(result.length));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _load() async {
    final data = await loadSniffingFile('trace');
    if (data == null || !mounted) return;
    _applyCapture(data, text.loaded(data.length));
  }

  Map<String, List<HFSniffNonce>> get _nonceGroups {
    final groups = <String, List<HFSniffNonce>>{};
    for (final nonce in _nonces) {
      groups.putIfAbsent(nonce.groupId, () => []).add(nonce);
    }
    return groups;
  }

  Future<void> _recoverKeys() async {
    if (_recovering) return;
    final candidates = _nonceGroups.values
        .where((records) => records.length >= 2)
        .toList(growable: false);
    if (candidates.isEmpty) return;
    setState(() {
      _recovering = true;
      _recoveryDone = 0;
      _recoveryTotal = candidates.length;
      _error = null;
    });

    try {
      for (final records in candidates) {
        final first = records[0];
        String? foundKey;
        for (var secondIndex = 1;
            secondIndex < records.length && foundKey == null;
            secondIndex++) {
          final second = records[secondIndex];
          final result = await recovery.mfkey32(recovery.Mfkey32Dart(
            uid: first.uid,
            nt0: first.nt,
            nt1: second.nt,
            nr0Enc: first.nr,
            ar0Enc: first.ar,
            nr1Enc: second.nr,
            ar1Enc: second.ar,
          ));
          if (result.isEmpty || result.first == -1) continue;
          final bytes = u64ToBytes(result.first);
          if (bytes.every((byte) => byte == 0xff)) continue;
          foundKey =
              bytesToHex(Uint8List.fromList(bytes.sublist(2, 8))).toUpperCase();
        }
        if (foundKey != null &&
            !_recoveredKeys.any((key) =>
                key.uid == first.uid &&
                key.block == first.block &&
                key.keyType == first.keyType)) {
          _recoveredKeys.add(_RecoveredSniffKey(
            uid: first.uid,
            block: first.block,
            keyType: first.keyType,
            key: foundKey,
          ));
        }
        if (!mounted) return;
        setState(() => _recoveryDone++);
      }
    } catch (error) {
      if (mounted) {
        setState(
            () => _error = error.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _recovering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<ChameleonGUIState>();
    final connected = appState.connector?.connected ?? false;

    return DefaultTabController(
      length: 5,
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Sniffing HF'),
            actions: [
              TextButton(
                onPressed: _capturing || _recovering
                    ? null
                    : () => Navigator.pop(context),
                child: Text(text.close),
              ),
            ],
          ),
          body: Column(
            children: [
              if (!connected)
                MaterialBanner(
                  content: Text(text.noDevice),
                  leading: const Icon(Icons.info_outline),
                  actions: const [SizedBox.shrink()],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 210,
                      child: TextField(
                        controller: _timeoutController,
                        enabled: !_capturing,
                        keyboardType: TextInputType.number,
                        decoration:
                            InputDecoration(labelText: text.captureTimeout),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: connected && !_capturing ? _capture : null,
                      icon: _capturing
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.radar),
                      label: Text(_capturing ? text.capturing : text.capture),
                    ),
                    OutlinedButton.icon(
                      onPressed: _rawCapture.isEmpty || _capturing
                          ? null
                          : () => saveSniffingFile(
                              _rawCapture, 'chameleon_hf_capture', 'trace'),
                      icon: const Icon(Icons.download),
                      label: Text(text.saveFile),
                    ),
                    OutlinedButton.icon(
                      onPressed: _capturing ? null : _load,
                      icon: const Icon(Icons.upload_file),
                      label: Text(text.loadFile('trace')),
                    ),
                    OutlinedButton.icon(
                      onPressed: _rawCapture.isEmpty
                          ? null
                          : () => Clipboard.setData(
                              ClipboardData(text: formatHexDump(_rawCapture))),
                      icon: const Icon(Icons.copy_all),
                      label: Text('${text.copyHex} grezzo'),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(_status!),
                ),
              TabBar(
                isScrollable: true,
                tabs: [
                  Tab(text: text.summary),
                  Tab(text: text.frames),
                  Tab(text: text.nonces),
                  Tab(text: text.recovery),
                  Tab(text: text.raw),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildSummary(),
                    _buildFrames(),
                    _buildNonces(),
                    _buildRecovery(),
                    _buildRaw(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummary() {
    if (_frames.isEmpty) return SniffEmptyView(text.noCapture);
    final readerFrames = _frames.where((frame) => !frame.tagToReader).length;
    final tagFrames = _frames.length - readerFrames;
    final authFrames = _frames
        .where((frame) =>
            !frame.tagToReader &&
            frame.data.isNotEmpty &&
            (frame.data[0] == 0x60 || frame.data[0] == 0x61))
        .length;
    final uids =
        _nonces.map((nonce) => nonce.uid).where((uid) => uid != 0).toSet();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SniffMetric(
            label: 'Frame acquisiti',
            value:
                '${_frames.length} totali · $readerFrames Reader → Tag · $tagFrames Tag → Reader',
            icon: Icons.swap_horiz),
        SniffMetric(
            label: 'Dati grezzi',
            value: '${_rawCapture.length} byte',
            icon: Icons.data_object),
        SniffMetric(
            label: 'Autenticazioni MIFARE Classic',
            value: '$authFrames richieste · ${_nonces.length} nonce completi',
            icon: Icons.lock_open),
        SniffMetric(
            label: 'UID osservati',
            value: uids.isEmpty
                ? 'Nessun UID completo ricostruito'
                : uids
                    .map((uid) =>
                        uid.toRadixString(16).padLeft(8, '0').toUpperCase())
                    .join(', '),
            icon: Icons.badge_outlined),
      ],
    );
  }

  Widget _buildFrames() {
    if (_frames.isEmpty) return SniffEmptyView(text.noCapture);
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _frames.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final frame = _frames[index];
        final color = frame.tagToReader
            ? Theme.of(context).colorScheme.tertiary
            : Theme.of(context).colorScheme.primary;
        return ListTile(
          leading: CircleAvatar(child: Text('${index + 1}')),
          title: Text(frame.description),
          subtitle: SelectableText(
            '${frame.direction} · ${frame.bits} bit\n${frame.hex}',
            style: const TextStyle(fontFamily: 'RobotoMono'),
          ),
          trailing: Icon(
            frame.tagToReader ? Icons.arrow_back : Icons.arrow_forward,
            color: color,
          ),
        );
      },
    );
  }

  Widget _buildNonces() {
    if (_frames.isEmpty) return SniffEmptyView(text.noCapture);
    if (_nonces.isEmpty) {
      return const SniffEmptyView(
          'Nessuna sequenza AUTH → NT → NR/AR completa trovata.');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _nonces.length,
      itemBuilder: (context, index) {
        final nonce = _nonces[index];
        return Card(
          child: ListTile(
            leading: CircleAvatar(child: Text('${index + 1}')),
            title: Text(
                'UID ${_hex32(nonce.uid)} · settore ${_sectorForBlock(nonce.block)} · Key ${nonce.keyType}'),
            subtitle: SelectableText(
              'Blocco ${nonce.block}\nNT ${_hex32(nonce.nt)}\nNR ${_hex32(nonce.nr)}\nAR ${_hex32(nonce.ar)}',
              style: const TextStyle(fontFamily: 'RobotoMono'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRecovery() {
    if (_frames.isEmpty) return SniffEmptyView(text.noCapture);
    final usableGroups =
        _nonceGroups.values.where((records) => records.length >= 2).length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          usableGroups == 0
              ? 'Servono almeno due nonce differenti con lo stesso UID, blocco e tipo di chiave.'
              : '$usableGroups gruppi compatibili pronti per MFKey32.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: usableGroups > 0 && !_recovering ? _recoverKeys : null,
          icon: _recovering
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.key),
          label: Text(_recovering
              ? 'Analisi $_recoveryDone/$_recoveryTotal'
              : 'Avvia recupero MFKey32'),
        ),
        if (_recovering) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(
              value:
                  _recoveryTotal == 0 ? null : _recoveryDone / _recoveryTotal),
        ],
        const SizedBox(height: 18),
        if (_recoveredKeys.isEmpty)
          const Text('Nessuna chiave recuperata.')
        else
          ..._recoveredKeys.map((result) => Card(
                child: ListTile(
                  leading: const Icon(Icons.vpn_key),
                  title: SelectableText(result.key,
                      style: const TextStyle(
                          fontFamily: 'RobotoMono',
                          fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      'UID ${_hex32(result.uid)} · settore ${_sectorForBlock(result.block)} · Key ${result.keyType}'),
                  trailing: IconButton(
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: result.key)),
                    icon: const Icon(Icons.copy),
                  ),
                ),
              )),
      ],
    );
  }

  Widget _buildRaw() {
    if (_rawCapture.isEmpty) return SniffEmptyView(text.noCapture);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        formatHexDump(_rawCapture),
        style: const TextStyle(fontFamily: 'RobotoMono'),
      ),
    );
  }
}

class _RecoveredSniffKey {
  final int uid;
  final int block;
  final String keyType;
  final String key;

  const _RecoveredSniffKey({
    required this.uid,
    required this.block,
    required this.keyType,
    required this.key,
  });
}

String _hex32(int value) =>
    value.toUnsigned(32).toRadixString(16).padLeft(8, '0').toUpperCase();

int _sectorForBlock(int block) {
  if (block < 128) return block ~/ 4;
  return 32 + ((block - 128) ~/ 16);
}
