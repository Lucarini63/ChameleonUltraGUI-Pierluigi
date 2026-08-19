import 'package:chameleonultragui/gui/menu/tools/sniffing_common.dart';
import 'package:chameleonultragui/helpers/definitions.dart';
import 'package:chameleonultragui/helpers/sniffing.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class LFSniffingMenu extends StatefulWidget {
  const LFSniffingMenu({super.key});

  @override
  State<LFSniffingMenu> createState() => _LFSniffingMenuState();
}

class _LFSniffingMenuState extends State<LFSniffingMenu> {
  final _timeoutController = TextEditingController(text: '2000');
  Uint8List _samples = Uint8List(0);
  bool _capturing = false;
  String? _error;
  String? _status;

  SniffingText get text =>
      SniffingText(Localizations.localeOf(context).languageCode == 'it');
  LFSniffAnalysis get analysis => LFSniffAnalysis.fromSamples(_samples);

  @override
  void dispose() {
    _timeoutController.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final appState = context.read<ChameleonGUIState>();
    if (!appState.connector!.connected || _capturing) return;
    final timeout =
        (int.tryParse(_timeoutController.text) ?? 2000).clamp(1, 10000);
    setState(() {
      _capturing = true;
      _error = null;
      _status = text.capturing;
    });
    try {
      final capabilities = await appState.communicator!.getDeviceCapabilities();
      if (!capabilities.contains(ChameleonCommand.lfSniff.value)) {
        throw Exception(text.unsupportedFirmware);
      }
      final result = await appState.communicator!.sniffLF(timeoutMs: timeout);
      if (!mounted) return;
      setState(() {
        _samples = Uint8List.fromList(result);
        _status = text.captured(result.length);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _load() async {
    final data = await loadSniffingFile('bin');
    if (data == null || !mounted) return;
    setState(() {
      _samples = data;
      _error = null;
      _status = text.loaded(data.length);
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<ChameleonGUIState>();
    final connected = appState.connector?.connected ?? false;
    final currentAnalysis = analysis;

    return DefaultTabController(
      length: 4,
      child: Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Sniffing LF'),
            actions: [
              TextButton(
                onPressed: _capturing ? null : () => Navigator.pop(context),
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
                          : const Icon(Icons.graphic_eq),
                      label: Text(_capturing ? text.capturing : text.capture),
                    ),
                    OutlinedButton.icon(
                      onPressed: _samples.isEmpty || _capturing
                          ? null
                          : () => saveSniffingFile(
                              _samples, 'chameleon_lf_capture', 'bin'),
                      icon: const Icon(Icons.download),
                      label: Text(text.saveFile),
                    ),
                    OutlinedButton.icon(
                      onPressed: _capturing ? null : _load,
                      icon: const Icon(Icons.upload_file),
                      label: Text(text.loadFile('bin')),
                    ),
                    OutlinedButton.icon(
                      onPressed: _samples.isEmpty
                          ? null
                          : () => Clipboard.setData(
                                ClipboardData(text: formatHexDump(_samples)),
                              ),
                      icon: const Icon(Icons.copy_all),
                      label: Text(text.copyHex),
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
                  Tab(text: text.waveform),
                  Tab(text: text.decoding),
                  Tab(text: text.hexadecimal),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildSummary(currentAnalysis),
                    _buildWaveform(currentAnalysis),
                    _buildDecoding(currentAnalysis),
                    _buildHex(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummary(LFSniffAnalysis value) {
    if (_samples.isEmpty) return SniffEmptyView(text.noCapture);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SniffMetric(
            label: 'Campioni',
            value: '${value.sampleCount} byte',
            icon: Icons.data_array),
        SniffMetric(
            label: 'Durata effettiva',
            value: '${value.durationMs.toStringAsFixed(3)} ms · 125 kHz',
            icon: Icons.timer_outlined),
        SniffMetric(
            label: 'Intervallo ADC',
            value:
                '0x${value.minimum.toRadixString(16).padLeft(2, '0').toUpperCase()} – 0x${value.maximum.toRadixString(16).padLeft(2, '0').toUpperCase()} · media ${value.average.toStringAsFixed(1)}',
            icon: Icons.multiline_chart),
        SniffMetric(
            label: 'Cadute di campo',
            value:
                '${value.gapSamples} campioni sotto la soglia 0x${value.threshold.toRadixString(16).padLeft(2, '0').toUpperCase()}',
            icon: Icons.ssid_chart),
      ],
    );
  }

  Widget _buildWaveform(LFSniffAnalysis value) {
    if (_samples.isEmpty) return SniffEmptyView(text.noCapture);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 20,
        constrained: false,
        child: CustomPaint(
          size: Size((_samples.length / 2).clamp(1200, 5000).toDouble(), 420),
          painter: LFWaveformPainter(
            samples: _samples,
            threshold: value.threshold,
            waveformColor: Theme.of(context).colorScheme.primary,
            gridColor: Theme.of(context).dividerColor.withValues(alpha: 0.35),
            thresholdColor: Theme.of(context).colorScheme.error,
          ),
        ),
      ),
    );
  }

  Widget _buildDecoding(LFSniffAnalysis value) {
    if (_samples.isEmpty) return SniffEmptyView(text.noCapture);
    final visibleRuns = value.runs.take(300).toList();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Livelli rilevati (1 = portante, 0 = caduta)',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(
          value.levelPreview.isEmpty
              ? 'Nessuna transizione rilevata'
              : value.levelPreview,
          style: const TextStyle(fontFamily: 'RobotoMono'),
        ),
        const SizedBox(height: 18),
        Text('Transizioni (${value.runs.length})',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...visibleRuns.map((run) => ListTile(
              dense: true,
              leading:
                  Icon(run.low ? Icons.arrow_downward : Icons.arrow_upward),
              title: Text(run.low ? 'Campo basso / gap' : 'Portante'),
              subtitle: Text(
                  'Campione ${run.startSample} · ${run.length} campioni · ${run.durationUs.toStringAsFixed(1)} µs'),
            )),
        if (value.runs.length > visibleRuns.length)
          Text('Mostrate le prime ${visibleRuns.length} transizioni.'),
      ],
    );
  }

  Widget _buildHex() {
    if (_samples.isEmpty) return SniffEmptyView(text.noCapture);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(
        formatHexDump(_samples),
        style: const TextStyle(fontFamily: 'RobotoMono'),
      ),
    );
  }
}
