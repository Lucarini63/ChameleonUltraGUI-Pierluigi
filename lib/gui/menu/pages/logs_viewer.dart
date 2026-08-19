import 'package:chameleonultragui/helpers/file_logger.dart';
import 'package:chameleonultragui/main.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// Localizations
import 'package:chameleonultragui/generated/i18n/app_localizations.dart';

class LogsViewerPage extends StatefulWidget {
  const LogsViewerPage({super.key});

  @override
  State<LogsViewerPage> createState() => LogsViewerPageState();
}

class LogsViewerPageState extends State<LogsViewerPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<ChameleonGUIState>();
    var localizations = AppLocalizations.of(context)!;
    final logs = appState.sharedPreferencesProvider.getLogLines();

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.logs),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: logs.length,
              itemBuilder: (context, index) {
                final log = logs[index];

                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: Theme.of(context).dividerColor,
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SelectableText(
                          log,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the tail of the log file. Reading is done once per open: the file is
/// appended to while a card is being read and a live view would fight with it.
class LogFileViewerPage extends StatefulWidget {
  const LogFileViewerPage({super.key});

  @override
  State<LogFileViewerPage> createState() => LogFileViewerPageState();
}

class LogFileViewerPageState extends State<LogFileViewerPage> {
  late Future<String> _contents;

  @override
  void initState() {
    super.initState();
    _contents = FileLog.read();
  }

  @override
  Widget build(BuildContext context) {
    var localizations = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.log_file),
        actions: [
          IconButton(
            onPressed: () =>
                setState(() => _contents = FileLog.read()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<String>(
        future: _contents,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final contents = snapshot.data ?? '';
          if (contents.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(FileLog.isActive
                    ? '${FileLog.path}\n\n(empty)'
                    : localizations.log_file_unavailable),
              ),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              contents,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          );
        },
      ),
    );
  }
}
